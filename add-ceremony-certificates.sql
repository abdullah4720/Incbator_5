-- ===== تحضير المشاركين في الحفل الختامي + شهادات المشاركة (أعضاء الفرق فقط) =====
-- شغّله مرة واحدة في Supabase SQL Editor (آمن للإعادة). يتطلب add-ceremony-rsvp.sql.

-- 1) إعدادات الشهادة
alter table form_settings add column if not exists cert_open    boolean not null default false;  -- فتح الشهادات للمشاركين
alter table form_settings add column if not exists cert_title   text;                            -- عنوان الشهادة
alter table form_settings add column if not exists cert_body    text;                            -- نص الشهادة ({الاسم} {المشروع} {التاريخ})
alter table form_settings add column if not exists cert_signers jsonb not null default '[]'::jsonb; -- [{name,title}]

-- 2) سجل التحضير: صف لكل عضو فريق حضر
create table if not exists ceremony_attendance (
  member_id     bigint primary key references team_members(id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  cert_code     text not null unique default ('INC5-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)))
);
alter table ceremony_attendance enable row level security;
drop policy if exists "admin all ceremony attendance" on ceremony_attendance;
create policy "admin all ceremony attendance" on ceremony_attendance for all to authenticated
  using (is_admin_or_reviewer()) with check (is_admin_or_reviewer());

-- 3) واجهة المشارك: شهادتي (برابطه الشخصي rsvp_token نفسه) — لا تظهر إلا إذا حضر وفُتحت الشهادات
create or replace function cert_get(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare m record; a record; s record; v_proj text;
begin
  select tm.id, tm.full_name, tm.form_id into m from team_members tm where tm.rsvp_token = p_token;
  if not found then return json_build_object('ok', false); end if;
  select * into s from form_settings where id = 1;
  select coalesce(nullif(btrim(tp.project_title),''), ep.project_name, vf.project_id) into v_proj
    from verification_forms vf left join eligible_projects ep on ep.project_id = vf.project_id left join teaser_profiles tp on tp.form_id = vf.id
   where vf.id = m.form_id;
  if not coalesce(s.cert_open, false) then return json_build_object('ok', true, 'open', false, 'name', m.full_name); end if;
  select * into a from ceremony_attendance where member_id = m.id;
  if not found then return json_build_object('ok', true, 'open', true, 'attended', false, 'name', m.full_name); end if;
  return json_build_object('ok', true, 'open', true, 'attended', true, 'name', m.full_name, 'project', v_proj, 'code', a.cert_code,
    'title', s.cert_title, 'body', s.cert_body, 'signers', s.cert_signers, 'date_text', s.ceremony_date_text);
end $$;
grant execute on function cert_get(uuid) to anon, authenticated;

-- 4) التحقق من شهادة برقمها
create or replace function cert_verify(p_code text) returns json
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select tm.full_name, a.cert_code, a.checked_in_at,
         (select coalesce(nullif(btrim(tp.project_title),''), ep.project_name, vf.project_id)
            from verification_forms vf left join eligible_projects ep on ep.project_id = vf.project_id left join teaser_profiles tp on tp.form_id = vf.id
           where vf.id = tm.form_id) as project,
         (select ceremony_date_text from form_settings where id = 1) as date_text
    into r
    from ceremony_attendance a join team_members tm on tm.id = a.member_id
   where upper(a.cert_code) = upper(btrim(p_code));
  if not found then return json_build_object('ok', false); end if;
  return json_build_object('ok', true, 'name', r.full_name, 'project', r.project, 'date_text', r.date_text, 'code', r.cert_code);
end $$;
grant execute on function cert_verify(text) to anon, authenticated;
