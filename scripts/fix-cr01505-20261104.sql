-- 단건 정정: 2026-04-22 성수에서 외국인 손님이 CR01505(스웻셔츠 22,000원)를 카드로 결제했다고 생각했으나 키오스크 조작 실수로
-- 결제가 안 된 줄 알고 현금으로 다시 결제했다. 알고 보니 카드도 결제돼 있어 다음 날(4/23) 카드를 취소했다.
-- 실제 흐름: 4/22 카드 +22,000 · 현금 +22,000, 4/23 카드 -22,000 → 순매출은 현금 +22,000(판매 완료). 허브 매출 리포트는 이렇게 계산돼 맞다.
-- 그런데 공동판매 시트 4/22 행에는 카드 +22,000 없이 현금 22,000만 있고(키오스크매출 칸 비어 있음) 4/23 행에는 카드 취소 -22,000이
-- 상품 환불로 들어가 순 0이 됐다. sold_items 는 바코드당 1행이라 4/23 환불 행(-22,000)만 남았고 재고는 in_stock 으로 남아 있었다.
-- 변경: sold_items 1행(환불 -22,000 → 4/22 판매 +22,000), inventory_items 1행(status → sold). 그 외는 건드리지 않는다.
-- (sync_sold_status 트리거는 INSERT에만 걸려 UPDATE로는 재고 상태가 안 바뀌므로 함께 갱신)
-- 공동판매 4월 엑셀은 그대로 둔다: 야간 동기화(sold_sync)는 전날만 읽고 reconcile은 입고 시트의 카테고리·가격만 보므로 이 정정이 되돌려지지 않는다.
-- 4/22 행에 키오스크매출 22,000을 보태면 결제금액이 44,000이 되어 sold_items 가격이 틀어지니 시트를 고치지 않는다.
-- resync_sold_items.py 를 4월에 수동 실행하면 되돌려지니 그때는 이 정정을 다시 적용할 것.
do $$
declare n_sold int; n_inv int;
begin
    update public.sold_items
       set sold_date = date '2026-04-22', price = 22000, refund_date = null, refund_type = null
     where id = '96d9af80-e7be-461b-bfbd-655d6a685ebc'
       and barcode = 'CR01505' and sold_date = date '2026-04-23' and price = -22000;
    get diagnostics n_sold = row_count;

    update public.inventory_items
       set status = 'sold'
     where id = 'a3ebed46-a693-43f8-8fec-71f588e27617'
       and barcode = 'CR01505' and status = 'in_stock' and price = 22000;
    get diagnostics n_inv = row_count;

    if n_sold <> 1 or n_inv <> 1 then
        raise exception '예상과 다른 행 수(sold_items=%, inventory_items=%) — 롤백', n_sold, n_inv;
    end if;
end $$;
