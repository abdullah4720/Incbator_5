-- ============================================================================
-- صفحة شركاء البرنامج — حاضنة ابتكار 5
-- كل شريك له رابط خاص (رمز سرّي) يعبّئ منه بياناته: معلومات الحفل الختامي،
-- دليل المشاركين (الخدمات)، الإعلام، العلاقات العامة. يُشغَّل مرة واحدة (آمن لإعادة التشغيل).
-- ============================================================================
create table if not exists partners (
  id           uuid primary key default gen_random_uuid(),
  token        uuid not null unique default gen_random_uuid(),
  org_name     text not null,
  sort_order   int  not null default 0,
  data         jsonb not null default '{}'::jsonb,
  is_locked    boolean not null default false,
  submitted_at timestamptz,
  updated_at   timestamptz not null default now(),
  created_at   timestamptz not null default now()
);
create unique index if not exists partners_org_name_key on partners(org_name);
alter table partners enable row level security;
drop policy if exists "admin all partners" on partners;
create policy "admin all partners" on partners for all to authenticated
  using (is_admin_or_reviewer()) with check (is_admin_or_reviewer());

-- الشركاء الخمسة عشر (حسب شريحة «شركاء النجاح»)
insert into partners (org_name, sort_order) values
  ('وزارة الاتصالات وتقنية المعلومات', 1),
  ('وزارة الصناعة والثروة المعدنية', 2),
  ('وزارة الطاقة', 3),
  ('وزارة الاقتصاد والتخطيط', 4),
  ('هيئة تنمية البحث والتطوير والابتكار', 5),
  ('الهيئة العامة للمنشآت الصغيرة والمتوسطة (منشآت)', 6),
  ('بنك المنشآت الصغيرة والمتوسطة', 7),
  ('الهيئة السعودية للبيانات والذكاء الاصطناعي (سدايا)', 8),
  ('الهيئة العامة للصناعات العسكرية', 9),
  ('البرنامج الوطني لتنمية تقنية المعلومات (ntdp)', 10),
  ('جامعة الملك عبدالله للعلوم والتقنية (كاوست)', 11),
  ('مدينة الملك عبدالله للطاقة الذرية والمتجددة (K.A.CARE)', 12),
  ('غرفة الرياض', 13),
  ('أمازون ويب سيرفيسز (AWS)', 14),
  ('مركز ريادة الأعمال الرقمية (CODE)', 15)
on conflict (org_name) do nothing;

-- جلب بيانات الشريك عبر الرمز
drop function if exists partner_get(uuid) cascade;
create or replace function partner_get(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare r partners%rowtype;
begin
  select * into r from partners where token = p_token;
  if not found then return json_build_object('ok', false); end if;
  return json_build_object('ok', true, 'id', r.id, 'org_name', r.org_name, 'data', r.data,
    'is_locked', r.is_locked, 'submitted_at', r.submitted_at, 'ceremony', ceremony_settings());
end $$;
grant execute on function partner_get(uuid) to anon, authenticated;

-- حفظ بيانات الشريك (p_submit = اعتماد وإرسال)
drop function if exists partner_save(uuid, jsonb, boolean) cascade;
create or replace function partner_save(p_token uuid, p_data jsonb, p_submit boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare r partners%rowtype; s jsonb; w int;
begin
  select * into r from partners where token = p_token;
  if not found then raise exception 'الرابط غير صحيح'; end if;
  if r.is_locked then raise exception 'تم قفل البيانات من قِبل فريق البرنامج'; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'صيغة البيانات غير صحيحة'; end if;
  if octet_length(p_data::text) > 200000 then raise exception 'حجم البيانات كبير جدًا'; end if;
  if jsonb_typeof(coalesce(p_data->'services','[]'::jsonb)) <> 'array' then raise exception 'صيغة الخدمات غير صحيحة'; end if;
  if jsonb_array_length(coalesce(p_data->'services','[]'::jsonb)) > 15 then raise exception 'الحد الأقصى 15 خدمة'; end if;
  for s in select * from jsonb_array_elements(coalesce(p_data->'services','[]'::jsonb)) loop
    w := case when btrim(coalesce(s->>'description','')) = '' then 0
              else array_length(regexp_split_to_array(btrim(s->>'description'), '\s+'), 1) end;
    if w > 100 then raise exception 'وصف الخدمة يتجاوز 100 كلمة'; end if;
  end loop;
  update partners set data = p_data, updated_at = now(),
         submitted_at = case when p_submit then now() else submitted_at end
   where id = r.id;
  return json_build_object('ok', true, 'submitted_at', (select submitted_at from partners where id = r.id));
end $$;
grant execute on function partner_save(uuid, jsonb, boolean) to anon, authenticated;

-- ملف الدليل المتكامل: يُرفع إلى form-attachments/partners/<partner_id>/...
create or replace function partner_files_ok(p_id text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from partners p where p.id::text = p_id and not p.is_locked);
$$;
grant execute on function partner_files_ok(text) to anon, authenticated;

drop policy if exists "upload partner files" on storage.objects;
create policy "upload partner files" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'form-attachments' and (storage.foldername(name))[1] = 'partners'
    and partner_files_ok((storage.foldername(name))[2]));

drop policy if exists "delete partner files" on storage.objects;
create policy "delete partner files" on storage.objects for delete to anon, authenticated
  using (bucket_id = 'form-attachments' and (storage.foldername(name))[1] = 'partners'
    and partner_files_ok((storage.foldername(name))[2]));
