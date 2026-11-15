-- 안전한 정리 묶음 (2026-11-15 구조 점검 결과). 모두 되돌리기 쉽고 앱 동작을 바꾸지 않는다.
-- 적용: supabase db query --linked -f scripts/safe-hardening-20261115.sql
begin;

-- 1) session_items 조회용 인덱스. PK 말고 인덱스가 없어 세션별·바코드별 조회가 매번 14만 행 전체를 훑었다.
--    되돌리기: drop index public.session_items_session_id_idx, public.session_items_barcode_idx;
create index if not exists session_items_session_id_idx on public.session_items (session_id);
create index if not exists session_items_barcode_idx on public.session_items (barcode);

-- 2) 비로그인(anon)이 실행할 수 있던 함수 3개 회수. 로그인 직원·service_role은 명시 GRANT가 있어 영향 없다.
--    hardening-step2의 'alter default privileges ... revoke execute ... from public'은 스키마 단위라
--    전역 기본값(PUBLIC 실행권)을 못 지운다. 새 함수는 만들 때마다 revoke execute ... from public, anon 을 직접 한다.
--    되돌리기: grant execute on function ... to anon;
revoke execute on function public.stocktake_refresh_stats() from public, anon;
revoke execute on function public.norm_category(text) from public, anon;
revoke execute on function public.purchase_item_kind(text) from public, anon;

-- 3) hardening-step2 5) 이후에 만든 테이블·뷰에 남은 불필요 권한 회수(TRUNCATE는 RLS를 우회한다).
--    되돌리기: grant truncate, references, trigger on ... to authenticated;
revoke truncate, references, trigger on
  public.corrections,
  public.purchase_batch_costs,
  public.purchase_batch_items,
  public.purchase_batches,
  public.purchase_items_v,
  public.purchase_sale_events_v,
  public.purchase_sale_exclusions,
  public.purchase_sales_legacy,
  public.purchase_snapshots,
  public.store_hangers
from authenticated;

-- 4) 이름(profiles.name)도 관리자만 바꾸게 한다. force_login_name 트리거가 이 이름으로 기록자를 덮어쓰므로
--    본인 프로필 수정 정책으로 이름을 바꾸면 기록자를 위조할 수 있었다. 앱의 이름 변경은 통합 관리(관리자)뿐이다.
--    되돌리기: hardening-step2-20261025.sql 7)의 함수 정의로 재생성.
create or replace function public.protect_profile_privileged_columns() returns trigger language plpgsql set search_path = '' as $fn$
begin
  if (new.role is distinct from old.role or new.is_handler is distinct from old.is_handler or new.email is distinct from old.email or new.name is distinct from old.name or new.id is distinct from old.id)
     and current_user in ('authenticated','anon')
     and not coalesce(public.is_admin(), false) then
    raise exception 'only admins can change role, handler flag, email or name' using errcode = '42501';
  end if;
  return new;
end $fn$;

commit;
