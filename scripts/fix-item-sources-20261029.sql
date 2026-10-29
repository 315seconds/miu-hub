-- 물건 출처 정정 6건(사용자 확인 2026-10-29). 공동판매 엑셀 입고시트와 DB 출처를 비교해 찾음.
--   A26001100, A26001101, A26001102, A26001147: 런드리고 → 택분실 (입고 때 런드리고로 잘못 잡았고, 엑셀만 수동 수정돼 있었음)
--   SB26082109: 런드리고 → 에코옥션 / SB26082225: 야후옥션 → 에코옥션 (SB2606 차시, 엑셀 입고시트는 이미 에코옥션)
-- inventory_items.source 만 바꾼다(행거 출처·가격·상태는 그대로). 현재 값이 예상과 다르면 롤백.
do $$
declare n int;
begin
    update public.inventory_items set source = '택분실'
     where barcode in ('A26001100', 'A26001101', 'A26001102', 'A26001147') and source = '런드리고';
    get diagnostics n = row_count;
    if n <> 4 then raise exception '택분실 정정: 예상 4행, 실제 % — 롤백', n; end if;

    update public.inventory_items set source = '에코옥션' where barcode = 'SB26082109' and source = '런드리고';
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'SB26082109: 예상 1행, 실제 % — 롤백', n; end if;

    update public.inventory_items set source = '에코옥션' where barcode = 'SB26082225' and source = '야후옥션';
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'SB26082225: 예상 1행, 실제 % — 롤백', n; end if;
end $$;
