-- 엑셀 입고시트에만 있고 DB에 없던 E3415~E3426 12건 보충 (2026-11-06)
-- 입고일 2026-07-29, 엑셀 직접 입고분이 sync_stock_items 에서 빠진 것. 바코드 UNIQUE 제약이 없어 NOT EXISTS 로 중복 방지.
-- 판매된 7건(E3415·3417·3418·3419·3420·3424·3426)은 sold_items 에 이미 있으므로 status='sold', 위치는 판매 매장.
insert into inventory_items (barcode, price, location, category, product_name, status, created_at)
select v.barcode, v.price, v.location, v.category, v.product_name, v.status, '2026-07-29T12:00:00+09:00'::timestamptz
from (values
  ('E3415', 78000, '성수',   '가방',   'e3415 가방',   'sold'),
  ('E3416', 42000, '성수',   '가방',   'e3416 가방',   'in_stock'),
  ('E3417', 40000, '성수',   '가방',   'e3417 가방',   'sold'),
  ('E3418', 26000, '성수',   '가방',   'e3418 가방',   'sold'),
  ('E3419', 20000, '성수',   '가방',   'e3419 가방',   'sold'),
  ('E3420', 16000, '성수',   '가방',   'e3420 가방',   'sold'),
  ('E3421', 22000, '성수',   'ETC',    'e3421 신발',   'in_stock'),
  ('E3422', 22000, '무성',   '모자',   'e3422 비니',   'in_stock'),
  ('E3423', 24000, '성수',   '패브릭', 'e3423 패브릭', 'in_stock'),
  ('E3424', 28000, '삼성',   'ETC',    'e3424 벨트',   'sold'),
  ('E3425', 30000, '온라인', 'ETC',    'e3425 머플러', 'in_stock'),
  ('E3426', 24000, '삼성',   'ETC',    'e3426 머플러', 'sold')
) as v(barcode, price, location, category, product_name, status)
where not exists (select 1 from inventory_items i where i.barcode = v.barcode);
