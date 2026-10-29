-- SB26082170 출처 채움: SB2606 차시 물건인데 DB 출처가 비어 있었다. 직원 확인으로 야후옥션(공동판매 엑셀 입고시트에는 10월 파일에 없음).
-- inventory_items.source 만 바꾼다. 현재 값이 비어 있지 않으면 롤백.
do $$
declare n int;
begin
    update public.inventory_items set source = '야후옥션' where barcode = 'SB26082170' and source is null;
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'SB26082170: 예상 1행, 실제 % — 롤백', n; end if;
end $$;
