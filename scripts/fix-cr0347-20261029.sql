-- 단건 정정: 2026-07-28 성수 현금매출이 바코드 CR0347로 잘못 기록돼(현금매출 시트 직원 입력 오타) sold_items에 들어갔고,
-- 시트·엑셀 판매시트는 다음 날 CR03347로 고쳤지만 DB는 못 고쳐 CR03347이 in_stock으로 남아 있었다.
-- 변경: sold_items 1행(바코드·상품명), inventory_items 1행(status → sold). 그 외는 건드리지 않는다.
-- (sync_sold_status 트리거는 INSERT에만 걸려 있어 바코드를 고쳐도 재고 상태가 안 바뀌므로 함께 갱신)
do $$
declare n_sold int; n_inv int;
begin
    update public.sold_items
       set barcode = 'CR03347', product_name = 'CR03347 스웻셔츠'
     where id = '683f9d20-c94d-4105-9702-0d3b12899031'
       and barcode = 'CR0347' and sold_date = date '2026-07-28' and price = 26000;
    get diagnostics n_sold = row_count;

    update public.inventory_items
       set status = 'sold'
     where barcode = 'CR03347' and status = 'in_stock' and price = 26000;
    get diagnostics n_inv = row_count;

    if n_sold <> 1 or n_inv <> 1 then
        raise exception '예상과 다른 행 수(sold_items=%, inventory_items=%) — 롤백', n_sold, n_inv;
    end if;
end $$;
