-- ===== سجل إشعارات المسجلين (تأكيد التسجيل / المقعد / تغيير المقعد / تذكير) + قوالب الرسائل =====
-- شغّله مرة واحدة في Supabase SQL Editor (آمن للإعادة).
alter table form_settings add column if not exists notify_templates jsonb not null default '{}'::jsonb;

create table if not exists ceremony_notices (
  id         bigint generated always as identity primary key,
  kind       text not null,          -- guest / member / partner / manual
  ref        text not null,
  event      text not null check (event in ('registration','seat','seat_change','reminder')),
  seat_no    int,                    -- رقم المقعد وقت الإشعار (لاكتشاف التغيير لاحقًا)
  channel    text,                   -- whatsapp / email / copy / manual
  created_at timestamptz not null default now()
);
create index if not exists ceremony_notices_ref_idx on ceremony_notices(kind, ref, event);
alter table ceremony_notices enable row level security;
drop policy if exists "admin all ceremony notices" on ceremony_notices;
create policy "admin all ceremony notices" on ceremony_notices for all to authenticated
  using (is_admin_or_reviewer()) with check (is_admin_or_reviewer());
