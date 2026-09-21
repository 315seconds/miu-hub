-- inventory_items.photo_url CHECK 제약 추가 (2026-09-15)
-- 목적: photo_url 값에 공백문자(개행/탭/스페이스 포함)가 있으면 INSERT/UPDATE 자체를 거부.
--       재발 시 데이터는 오염되지 않고 즉시 에러로 감지됨.
-- 전제: 현재 오염된 행이 0건이어야 함. 실행 전 반드시 아래 사전 점검 쿼리로 확인할 것.
-- 사용: Supabase 대시보드 → SQL Editor → 이 파일 전체 복사·붙여넣기 → Run.

-- ─── 사전 점검 ─────────────────────────────────────────────────────────
-- 이 결과가 0이 아니면 아래 ALTER TABLE은 실패함. 먼저 오염 행을 정리하고 다시 실행.
select count(*) as corrupted_rows
from public.inventory_items
where photo_url ~ '\s';

-- ─── 제약 추가 ─────────────────────────────────────────────────────────
alter table public.inventory_items
  add constraint inventory_items_photo_url_no_whitespace
  check (photo_url is null or photo_url !~ '\s');

comment on constraint inventory_items_photo_url_no_whitespace on public.inventory_items is
  'photo_url에 공백문자(개행/탭/스페이스) 유입 방지. 09-11, 09-15 오전 시간대 save_item_capture 함수 소스 오염으로 URL이 깨져 저장된 사고 후속 조치.';
