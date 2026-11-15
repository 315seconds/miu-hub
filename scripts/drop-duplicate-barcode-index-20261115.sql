-- inventory_items.barcode 중복 인덱스 제거. UNIQUE 인덱스 inventory_items_barcode_key가 이미 같은 컬럼을 덮고 있어
-- 일반 인덱스 inventory_items_barcode_idx(약 3.5MB)는 쓰기 비용만 늘린다.
-- 되돌리기: create index inventory_items_barcode_idx on public.inventory_items (barcode);
drop index if exists public.inventory_items_barcode_idx;
