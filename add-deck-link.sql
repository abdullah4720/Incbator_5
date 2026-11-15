-- رابط ثابت لملف عرض المشروع المُحكَّم (deck.html?p=رقم_المشروع) — صالح دائمًا ويصلح لرمز QR
-- يعمل فقط للمشاريع المُحكَّمة (مُسنَدة للجنة + تقييم مُرسَل) التي رفعت عرضًا. شغّله مرة واحدة (آمن للإعادة).

create or replace function deck_info(p_project_id text)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object('ok', true,
              'project_id', vf.project_id,
              'project_name', coalesce(nullif(btrim(tp.project_title),''), ep.project_name, vf.project_id),
              'file_name', jp.file_name,
              'storage_path', jp.storage_path)
       from verification_forms vf
       join judging_presentations jp on jp.form_id = vf.id
       left join teaser_profiles tp on tp.form_id = vf.id
       left join eligible_projects ep on ep.project_id = vf.project_id
      where vf.project_id = p_project_id
        and teaser_is_eligible(vf.id)
      order by jp.uploaded_at desc
      limit 1),
    jsonb_build_object('ok', false));
$$;
grant execute on function deck_info(text) to anon, authenticated;

-- السماح بقراءة ملف العرض (فقط) للمشاريع المُحكَّمة، حتى يُنشئ رابط الفتح بدون تسجيل دخول
drop policy if exists "public read judged presentations" on storage.objects;
create policy "public read judged presentations"
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'form-attachments'
    and (storage.foldername(name))[2] = 'judging-presentation'
    and exists (
      select 1 from judging_presentations jp
      where jp.storage_path = storage.objects.name
        and teaser_is_eligible(jp.form_id)
    )
  );

-- ===== شعار المشروع: رابط ثابت (logo.html?p=رقم_المشروع) =====
create or replace function logo_info(p_project_id text)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object('ok', true,
              'project_id', vf.project_id,
              'project_name', coalesce(nullif(btrim(tp.project_title),''), ep.project_name, vf.project_id),
              'file_name', coalesce(tp.logo_name, 'logo'),
              'storage_path', tp.logo_path)
       from verification_forms vf
       join teaser_profiles tp on tp.form_id = vf.id
       left join eligible_projects ep on ep.project_id = vf.project_id
      where vf.project_id = p_project_id
        and tp.logo_path is not null
        and teaser_is_eligible(vf.id)
      limit 1),
    jsonb_build_object('ok', false));
$$;
grant execute on function logo_info(text) to anon, authenticated;

drop policy if exists "public read judged logos" on storage.objects;
create policy "public read judged logos"
  on storage.objects for select
  to anon, authenticated
  using (
    bucket_id = 'form-attachments'
    and (storage.foldername(name))[2] = 'teaser-logo'
    and exists (
      select 1 from teaser_profiles tp
      where tp.logo_path = storage.objects.name
        and teaser_is_eligible(tp.form_id)
    )
  );
