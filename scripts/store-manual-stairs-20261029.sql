-- "계단 있는매장 계단 청소." 를 공통 항목에서 홍대입구 전용 항목으로 (현재 계단이 있는 매장은 홍대입구뿐)
-- 적용: supabase db query --linked -f scripts/store-manual-stairs-20261029.sql
-- 다른 매장에 계단이 생기면 관리자 화면(manual/admin.html → 체크리스트 편집)에서 그 매장 전용 항목으로 추가한다.
update public.checklist_items
set store = '홍대입구', content = '계단 청소'
where store is null and content = '계단 있는매장 계단 청소.';
