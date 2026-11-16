-- إصلاح: "new row violates row-level security policy" عند رفع ملف الدليل في صفحة الشركاء
-- السبب: سياسة الرفع كانت تتحقق من جدول partners مباشرة، وهو غير مقروء للزائر (anon) بسبب RLS،
-- فيُرفض الرفع دائمًا. الحل: دالة SECURITY DEFINER تتحقق نيابةً عن الزائر. شغّله مرة واحدة (آمن للإعادة).

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
