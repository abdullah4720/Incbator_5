-- ===== مقاعد الحفل الختامي: مخطط القاعة + تخصيص المقاعد + بطاقة الدعوة =====
-- شغّله مرة واحدة في Supabase SQL Editor (آمن للإعادة). يتطلب: add-ceremony-rsvp / add-ceremony-guests / add-ceremony-judged-only.

-- 1) إعدادات القاعة (قابلة للتعديل من لوحة الإدارة)
alter table form_settings add column if not exists seats_cols            int not null default 4;   -- عدد الكتل في الصف الواحد
alter table form_settings add column if not exists seats_block_rows      int not null default 2;   -- عدد صفوف الكتل (من المنصة للخلف)
alter table form_settings add column if not exists seats_rows_per_block  int not null default 2;   -- صفوف المقاعد داخل الكتلة
alter table form_settings add column if not exists seats_per_row         int not null default 5;   -- مقاعد الصف الواحد داخل الكتلة
alter table form_settings add column if not exists seats_blocked         int[] not null default '{}'; -- مقاعد مستبعدة (ممرات/صيانة)
alter table form_settings add column if not exists seats_published       boolean not null default false; -- إظهار المقعد للحضور
alter table form_settings add column if not exists seats_gate            text;                      -- رقم/اسم البوابة

-- 2) جدول التخصيص: مقعد واحد لكل شخص
create table if not exists ceremony_seats (
  seat_no   int primary key check (seat_no > 0),
  kind      text not null check (kind in ('guest','member','manual')),
  ref       text not null,                -- id الضيف / id عضو الفريق / معرّف يدوي
  name      text not null,
  org       text,
  tier      text not null default 'ضيف',  -- الفئة المعروضة على البطاقة (VIP / مشارك / ضيف / شريك ...)
  locked    boolean not null default false,
  assigned_at timestamptz not null default now(),
  unique (kind, ref)
);
alter table ceremony_seats enable row level security;
drop policy if exists "admin all ceremony seats" on ceremony_seats;
create policy "admin all ceremony seats" on ceremony_seats for all to authenticated
  using (is_admin_or_reviewer()) with check (is_admin_or_reviewer());

-- 3) أدوات داخلية
create or replace function seats_total() returns int
language sql stable security definer set search_path = public as $$
  select seats_cols * seats_block_rows * seats_rows_per_block * seats_per_row from form_settings where id = 1;
$$;

-- كل من أكّد حضوره (ضيوف معتمدون + أعضاء فرق مؤكدون) — للاستخدام الداخلي فقط
create or replace function seats_pool() returns table(kind text, ref text, name text, org text, tier text, sort_key text)
language sql stable security definer set search_path = public as $$
  select 'guest'::text, g.id::text, g.full_name, g.org,
         case g.category when 'invited' then 'VIP' else 'ضيف' end,
         to_char(g.created_at, 'YYYYMMDDHH24MISSUS')
    from ceremony_guests g where g.status = 'approved'
  union all
  select 'member'::text, tm.id::text, tm.full_name,
         coalesce(nullif(btrim(tp.project_title),''), ep.project_name, vf.project_id), 'مشارك',
         coalesce(vf.project_id,'') || lpad(tm.id::text, 10, '0')
    from ceremony_rsvp r
    join team_members tm on tm.id = r.member_id
    join verification_forms vf on vf.id = tm.form_id
    left join eligible_projects ep on ep.project_id = vf.project_id
    left join teaser_profiles tp on tp.form_id = vf.id
   where r.status = 'attending';
$$;
revoke all on function seats_pool() from public, anon, authenticated;
revoke all on function seats_total() from public, anon, authenticated;

-- 4) الحالة الكاملة للوحة الإدارة
create or replace function seats_state() returns json
language plpgsql stable security definer set search_path = public as $$
declare v json;
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  select json_build_object(
    'ok', true,
    'hall', (select json_build_object('cols', seats_cols, 'block_rows', seats_block_rows, 'rows_per_block', seats_rows_per_block,
                                      'seats_per_row', seats_per_row, 'blocked', seats_blocked, 'published', seats_published, 'gate', seats_gate,
                                      'total', seats_total()) from form_settings where id = 1),
    'seats', (select coalesce(json_agg(json_build_object('seat_no', seat_no, 'kind', kind, 'ref', ref, 'name', name, 'org', org, 'tier', tier, 'locked', locked) order by seat_no), '[]'::json) from ceremony_seats),
    'unseated', (select coalesce(json_agg(json_build_object('kind', p.kind, 'ref', p.ref, 'name', p.name, 'org', p.org, 'tier', p.tier) order by p.tier, p.sort_key), '[]'::json)
                   from seats_pool() p where not exists (select 1 from ceremony_seats s where s.kind = p.kind and s.ref = p.ref)),
    'stale', (select coalesce(json_agg(s.seat_no order by s.seat_no), '[]'::json) from ceremony_seats s
               where s.kind in ('guest','member') and not exists (select 1 from seats_pool() p where p.kind = s.kind and p.ref = s.ref))
  ) into v;
  return v;
end $$;
grant execute on function seats_state() to authenticated;

-- 5) تخصيص تلقائي: يرتّب الفئات (VIP ثم المشاركون — مجمّعين حسب المشروع — ثم الضيوف) ويملأ المقاعد من الأمام
create or replace function seats_autoassign(p_order text[] default array['VIP','شريك','مشارك','ضيف']) returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_blocked int[]; r record; v_seat int; v_placed int := 0; v_left int := 0; v_freed int;
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  perform pg_advisory_xact_lock(7002);
  select seats_total(), seats_blocked into v_total, v_blocked from form_settings where id = 1;
  -- إخلاء مقاعد من ألغوا/اعتذروا (غير المثبّتة)
  delete from ceremony_seats s
   where s.kind in ('guest','member') and not s.locked
     and not exists (select 1 from seats_pool() p where p.kind = s.kind and p.ref = s.ref);
  get diagnostics v_freed = row_count;
  for r in
    select p.* from seats_pool() p
     where not exists (select 1 from ceremony_seats s where s.kind = p.kind and s.ref = p.ref)
     order by coalesce(array_position(p_order, p.tier), 99), p.sort_key
  loop
    select min(n) into v_seat from generate_series(1, v_total) n
     where n <> all (v_blocked) and not exists (select 1 from ceremony_seats s where s.seat_no = n);
    if v_seat is null then v_left := v_left + 1; continue; end if;
    insert into ceremony_seats(seat_no, kind, ref, name, org, tier) values (v_seat, r.kind, r.ref, r.name, r.org, r.tier);
    v_placed := v_placed + 1;
  end loop;
  return json_build_object('ok', true, 'placed', v_placed, 'unplaced', v_left, 'freed', v_freed);
end $$;
grant execute on function seats_autoassign(text[]) to authenticated;

-- 6) نقل/تبديل يدوي: يضع الشخص في المقعد (إن كان المقعد مشغولًا بغير مثبّت يتبادلان)
create or replace function seat_assign(p_kind text, p_ref text, p_seat int) returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_blocked int[]; v_cur record; v_oth record; v_p record;
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  perform pg_advisory_xact_lock(7002);
  select seats_total(), seats_blocked into v_total, v_blocked from form_settings where id = 1;
  if p_seat < 1 or p_seat > v_total or p_seat = any (v_blocked) then return json_build_object('ok', false, 'reason', 'invalid_seat'); end if;
  select * into v_cur from ceremony_seats where kind = p_kind and ref = p_ref;
  select * into v_oth from ceremony_seats where seat_no = p_seat;
  if v_cur.seat_no is not null and v_cur.seat_no = p_seat then return json_build_object('ok', true); end if;
  if v_cur.seat_no is not null and v_cur.locked then return json_build_object('ok', false, 'reason', 'locked'); end if;
  if v_oth.seat_no is not null and v_oth.locked then return json_build_object('ok', false, 'reason', 'target_locked'); end if;
  if v_cur.seat_no is null then
    select * into v_p from seats_pool() where kind = p_kind and ref = p_ref;
    if not found then return json_build_object('ok', false, 'reason', 'not_found'); end if;
    if v_oth.seat_no is not null then delete from ceremony_seats where seat_no = p_seat; end if;
    insert into ceremony_seats(seat_no, kind, ref, name, org, tier) values (p_seat, v_p.kind, v_p.ref, v_p.name, v_p.org, v_p.tier);
  elsif v_oth.seat_no is null then
    update ceremony_seats set seat_no = p_seat, assigned_at = now() where kind = p_kind and ref = p_ref;
  else
    delete from ceremony_seats where seat_no in (v_cur.seat_no, p_seat);
    insert into ceremony_seats(seat_no, kind, ref, name, org, tier, locked) values
      (p_seat, v_cur.kind, v_cur.ref, v_cur.name, v_cur.org, v_cur.tier, v_cur.locked),
      (v_cur.seat_no, v_oth.kind, v_oth.ref, v_oth.name, v_oth.org, v_oth.tier, v_oth.locked);
  end if;
  return json_build_object('ok', true);
end $$;
grant execute on function seat_assign(text, text, int) to authenticated;

-- 7) إخلاء مقعد / تثبيته / تغيير الفئة / إضافة شخص يدويًا / مسح الكل
create or replace function seat_free(p_seat int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  delete from ceremony_seats where seat_no = p_seat;
  return json_build_object('ok', true);
end $$;
grant execute on function seat_free(int) to authenticated;

create or replace function seat_set_flags(p_seat int, p_locked boolean default null, p_tier text default null) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  update ceremony_seats set locked = coalesce(p_locked, locked), tier = coalesce(nullif(btrim(p_tier),''), tier) where seat_no = p_seat;
  return json_build_object('ok', true);
end $$;
grant execute on function seat_set_flags(int, boolean, text) to authenticated;

create or replace function seat_add_manual(p_name text, p_org text, p_tier text, p_seat int default null) returns json
language plpgsql security definer set search_path = public as $$
declare v_total int; v_blocked int[]; v_seat int := p_seat;
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  if btrim(coalesce(p_name,'')) = '' then return json_build_object('ok', false, 'reason', 'name'); end if;
  perform pg_advisory_xact_lock(7002);
  select seats_total(), seats_blocked into v_total, v_blocked from form_settings where id = 1;
  if v_seat is null then
    select min(n) into v_seat from generate_series(1, v_total) n
     where n <> all (v_blocked) and not exists (select 1 from ceremony_seats s where s.seat_no = n);
  end if;
  if v_seat is null or v_seat > v_total or v_seat = any (v_blocked) or exists (select 1 from ceremony_seats where seat_no = v_seat) then
    return json_build_object('ok', false, 'reason', 'no_seat');
  end if;
  insert into ceremony_seats(seat_no, kind, ref, name, org, tier, locked)
  values (v_seat, 'manual', gen_random_uuid()::text, btrim(p_name), nullif(btrim(coalesce(p_org,'')),''), coalesce(nullif(btrim(p_tier),''), 'ضيف'), true);
  return json_build_object('ok', true, 'seat_no', v_seat);
end $$;
grant execute on function seat_add_manual(text, text, text, int) to authenticated;

create or replace function seats_clear(p_keep_locked boolean default true) returns json
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin_or_reviewer() then return json_build_object('ok', false, 'reason', 'forbidden'); end if;
  delete from ceremony_seats where not (p_keep_locked and locked);
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'removed', n);
end $$;
grant execute on function seats_clear(boolean) to authenticated;

-- 8) واجهة الزائر: مقعدي (بعد النشر فقط) — للمدعو (token الضيف) ولعضو الفريق (rsvp_token)
create or replace function seat_hall_public() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('cols', seats_cols, 'block_rows', seats_block_rows, 'rows_per_block', seats_rows_per_block,
                           'seats_per_row', seats_per_row, 'blocked', seats_blocked, 'gate', seats_gate)
  from form_settings where id = 1;
$$;
revoke all on function seat_hall_public() from public, anon, authenticated;

create or replace function seat_of_guest(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare g record; s record; v_pub boolean;
begin
  select seats_published into v_pub from form_settings where id = 1;
  select * into g from ceremony_guests where token = p_token and status = 'approved';
  if not found then return json_build_object('ok', false); end if;
  if not coalesce(v_pub, false) then return json_build_object('ok', true, 'published', false); end if;
  select * into s from ceremony_seats where kind = 'guest' and ref = g.id::text;
  if not found then return json_build_object('ok', true, 'published', true, 'seat', null); end if;
  return json_build_object('ok', true, 'published', true, 'seat', json_build_object('no', s.seat_no, 'tier', s.tier), 'hall', seat_hall_public());
end $$;
grant execute on function seat_of_guest(uuid) to anon, authenticated;

create or replace function seat_of_member(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare m record; s record; v_pub boolean;
begin
  select seats_published into v_pub from form_settings where id = 1;
  select tm.id into m from team_members tm join ceremony_rsvp r on r.member_id = tm.id and r.status = 'attending' where tm.rsvp_token = p_token;
  if not found then return json_build_object('ok', false); end if;
  if not coalesce(v_pub, false) then return json_build_object('ok', true, 'published', false); end if;
  select * into s from ceremony_seats where kind = 'member' and ref = m.id::text;
  if not found then return json_build_object('ok', true, 'published', true, 'seat', null); end if;
  return json_build_object('ok', true, 'published', true, 'seat', json_build_object('no', s.seat_no, 'tier', s.tier), 'hall', seat_hall_public());
end $$;
grant execute on function seat_of_member(uuid) to anon, authenticated;
