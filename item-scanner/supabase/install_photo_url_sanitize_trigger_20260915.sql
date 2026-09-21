-- photo_url 자동 정정 트리거 + 정정 로그 테이블 (2026-09-15)
-- 목적: inventory_items.photo_url에 공백문자가 섞인 값이 들어오면
--       저장 직전에 자동으로 공백 제거 + 별도 로그 테이블에 기록.
--       이번 사고(save_item_capture 함수 소스 오염)와 같은 재발 시
--       앱은 정상 동작하고 데이터도 자동 정정됨.
-- 사용: supabase db query --linked -f 이 파일

create schema if not exists private;

-- ─── 정정 로그 테이블 ─────────────────────────────────────────────────
create table if not exists private.photo_url_sanitize_log (
  id             bigserial primary key,
  inventory_item_id uuid not null,
  barcode        text,
  original_value text not null,
  sanitized_value text not null,
  triggered_at   timestamptz not null default now(),
  operation      text not null
);

comment on table private.photo_url_sanitize_log is
  'photo_url 자동 정정 발생 로그. 오염된 URL이 들어와 트리거가 공백 제거한 이력. 재발 감지용.';

create index if not exists photo_url_sanitize_log_triggered_at_idx
  on private.photo_url_sanitize_log (triggered_at desc);

-- ─── 트리거 함수 ──────────────────────────────────────────────────────
create or replace function private.sanitize_photo_url()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  sanitized text;
begin
  if new.photo_url is null then
    return new;
  end if;

  sanitized := regexp_replace(new.photo_url, '\s+', '', 'g');

  if sanitized <> new.photo_url then
    insert into private.photo_url_sanitize_log
      (inventory_item_id, barcode, original_value, sanitized_value, operation)
    values
      (new.id, new.barcode, new.photo_url, sanitized, tg_op);
    new.photo_url := sanitized;
  end if;

  return new;
end;
$$;

comment on function private.sanitize_photo_url() is
  'BEFORE INSERT/UPDATE 트리거: photo_url에서 공백문자를 자동 제거하고 발생 시 로그 기록.';

-- ─── 트리거 부착 ──────────────────────────────────────────────────────
drop trigger if exists inventory_items_sanitize_photo_url on public.inventory_items;
create trigger inventory_items_sanitize_photo_url
  before insert or update of photo_url on public.inventory_items
  for each row
  execute function private.sanitize_photo_url();

-- ─── 배포 검증 ────────────────────────────────────────────────────────
select
  tgname as trigger_name,
  tgenabled as enabled_flag,
  (select proname from pg_proc where oid = tgfoid) as function_name
from pg_trigger
where tgrelid = 'public.inventory_items'::regclass
  and tgname = 'inventory_items_sanitize_photo_url';
