-- 마켓인유 허브 2단계: 비로그인 차단 + 권한 정리 (적용 전 초안)
begin;
-- 1) 비로그인(anon/public) 정책 삭제
drop policy "anon_select" on public."approvers";
drop policy "allow anon select" on public."brand_master";
drop policy "anon read" on public."calendar_events";
drop policy "anon write" on public."calendar_events";
drop policy "anon_all" on public."handlers";
drop policy "device can delete own hanger scans" on public."hanger_scans";
drop policy "device can read own hanger scans" on public."hanger_scans";
drop policy "anon_all" on public."inventory_hangers";
drop policy "anon_all" on public."inventory_items";
drop policy "anon_all" on public."inventory_sessions";
drop policy "device can read own captures" on public."item_captures";
drop policy "anon_all" on public."kiosk_updates";
drop policy "anon_all" on public."locations";
drop policy "anon_all" on public."move_sessions";
drop policy "anon_all" on public."price_changes";
drop policy "device can complete own hangers" on public."scan_hangers";
drop policy "device can delete own hangers" on public."scan_hangers";
drop policy "device can read own hangers" on public."scan_hangers";
drop policy "anon_all" on public."session_items";
drop policy "anon_select" on public."sold_items";
drop policy "anon_all" on public."sources";
drop policy "anon_all" on public."stocktake_scans";
drop policy "anon_all" on public."stocktake_sessions";
drop policy "allow anon select" on storage."objects";
drop policy "allow anon update" on storage."objects";
drop policy "allow anon upload" on storage."objects";
drop policy "allow_insert_stocktake_reports" on storage."objects";
drop policy "allow_select_stocktake_reports" on storage."objects";
drop policy "allow_update" on storage."objects";
drop policy "allow_update_stocktake_reports" on storage."objects";
drop policy "allow_upload" on storage."objects";
drop policy "anon can upload item photos" on storage."objects";
-- 2) 삭제로 비는 구간 보완: 달력, 재고조사 보고서 저장소는 로그인 직원 전용으로 재생성
create policy authenticated_all on public.calendar_events for all to authenticated using (true) with check (true);
create policy authenticated_select_stocktake_reports on storage.objects for select to authenticated using (bucket_id = 'stocktake-reports');
create policy authenticated_insert_stocktake_reports on storage.objects for insert to authenticated with check (bucket_id = 'stocktake-reports');
create policy authenticated_update_stocktake_reports on storage.objects for update to authenticated using (bucket_id = 'stocktake-reports') with check (bucket_id = 'stocktake-reports');
-- 3) 컬러 라벨 도구 전용 최소 예외 (판매 중 상품 읽기, 색상이 빈 상품의 색상·패턴만 쓰기)
create policy anon_color_tool_select on public.inventory_items for select to anon using (status = 'in_stock');
create policy anon_color_tool_update on public.inventory_items for update to anon using (color is null and status = 'in_stock') with check (status = 'in_stock');
-- 4) 비로그인 테이블·시퀀스·함수·스키마 권한 회수
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from anon, public;
revoke execute on all functions in schema private from anon, public;
revoke usage on schema private from anon;
grant select on public.inventory_items to anon;
grant update (color, pattern) on public.inventory_items to anon;
-- 5) 로그인 직원에게도 불필요한 권한 회수, 쓰지 않는 PIN 테이블 차단
revoke truncate, references, trigger on all tables in schema public from authenticated;
revoke all on public.approvers from authenticated;
-- 6) 앞으로 만들 테이블이 비로그인에게 자동 개방되지 않도록
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon, public;
-- 7) 일반 직원이 등급·담당자 여부·이메일을 못 바꾸게 보호
create or replace function public.protect_profile_privileged_columns() returns trigger language plpgsql set search_path = '' as $fn$
begin
  if (new.role is distinct from old.role or new.is_handler is distinct from old.is_handler or new.email is distinct from old.email or new.id is distinct from old.id)
     and current_user in ('authenticated','anon')
     and not coalesce(public.is_admin(), false) then
    raise exception 'only admins can change role, handler flag or email' using errcode = '42501';
  end if;
  return new;
end $fn$;
drop trigger if exists protect_profile_privileged_columns on public.profiles;
create trigger protect_profile_privileged_columns before update on public.profiles for each row execute function public.protect_profile_privileged_columns();
-- 8) 죽은 DB 웹훅 제거 (옛 서버 43.202.62.74로 이동 승인 때마다 POST, 현재 응답 없음)
drop trigger if exists "move-approved" on public.move_sessions;
commit;
