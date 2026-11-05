-- 판매 시트(전매장매출)에는 있는데 DB sold_items 에 빠졌거나 오타 바코드로 남은 판매 정정 (2026-11-05, 운영 DB 적용 완료)
-- 원인: sold_sync 는 '어제 날짜 행'만 한 번 읽어 upsert(바코드 기준). 입력 당시 바코드 오타였다가 나중에 시트에서 고쳐지면 DB 에는 오타 행이 남고(재고 없음) 올바른 바코드의 판매는 영영 안 들어온다.
--       오타가 실제 다른 물건 바코드이면 그 물건의 판매 날짜를 덮어쓴다(C89487).
-- 점검: 4~11월 시트 바코드 30,730개 vs DB — 누락 10건, DB에만 있는 오타 4건, 날짜 덮임 1건이 전부였다. 전/후 값은 맥 ~/backups/sold_items_before_20261105.json
begin;
create temp table _ins on commit drop as
select v.b, v.d, v.s, v.p, coalesce(i.product_name,'') pn from (values ('CR03196',date '2026-07-14','공동판매성수',22000),('XD635',date '2026-07-16','공동판매성수',9900),('C87328',date '2026-07-20','공동판매성수',24000),('C79490',date '2026-08-17','공동판매성수',14000),('C91738',date '2026-08-21','공동판매성수',18000),('C10545',date '2026-08-28','공동판매성수',20000),('C84501',date '2026-08-29','공동판매좋은습관',6800),('C87904',date '2026-09-13','공동판매좋은습관',6800),('C95580',date '2026-09-17','공동판매성수',9800),('C96675',date '2026-09-23','공동판매성수',6800)) v(b,d,s,p) left join public.inventory_items i on i.barcode=v.b;
-- 1) 빠진 판매 10건 입력 (재고 상태는 sync_sold_status 트리거가 sold 로)
insert into public.sold_items (barcode, sold_date, store, product_name, price, quantity)
select b, d, s, pn, p, 1 from _ins where not exists (select 1 from public.sold_items x where x.barcode=_ins.b);
-- 2) 오타 바코드로 남은 판매 4건 삭제(재고에 없는 바코드, 같은 날·매장·가격의 올바른 판매를 1)에서 입력)
delete from public.sold_items s using (values ('R03196',date '2026-07-14',22000),('XD365',date '2026-07-16',9900),('C799490',date '2026-08-17',14000),('C910545',date '2026-08-28',20000)) t(b,d,p)
 where s.barcode=t.b and s.sold_date=t.d and s.price=t.p and not exists (select 1 from public.inventory_items i where i.barcode=s.barcode);
-- 3) 다른 오타 판매에 날짜가 덮인 C89487: 엑셀 기준 8/28
update public.sold_items set sold_date=date '2026-08-28' where barcode='C89487' and sold_date=date '2026-08-29' and price=6800;
-- 4) 위탁종료에 있던 기존 재고 14건: 최종 위치 트리거를 거치게 해서 disposed 로(판매된 XD635 는 위 1)에서 sold)
update public.inventory_items set location=location where location='위탁종료' and status='in_stock';
commit;
