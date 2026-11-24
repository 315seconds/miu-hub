-- 에코옥션 2026년 7차(SB2607) 최초 프라이싱 정정 (일회성, 2026-11-24)
--   입고 때 프라이싱을 잘못 넣어 11/20 09:20에 37벌의 가격을 올려 고쳤는데, purchase_batch_items.initial_price(최초 프라이싱)는
--   잘못 넣은 가격 그대로라 원가 안분 기준이 틀어져 있었다. 고친 가격을 최초 프라이싱으로 쓴다(= 현재 프라이싱 합과 일치).
--   원래 값은 price_changes.old_price(11/20 09:20 행)에 남아 있다.
-- 안전장치: 차시 SB2607 의류 136벌, 정정 전 최초 프라이싱 합 31,948,000 / 정정 후 33,208,000 이 아니면 예외로 전체 취소.

do $$
declare
    v_batch uuid; v_n integer; v_before bigint; v_after bigint; v_cur bigint;
begin
    select id into v_batch from public.purchase_batches where code = 'SB2607';
    if v_batch is null then raise exception 'SB2607 차시 없음'; end if;

    select count(*), sum(initial_price) into v_n, v_before
      from public.purchase_batch_items where batch_id = v_batch and not excluded;
    if v_n <> 136 or v_before <> 31948000 then
        raise exception '정정 전 상태 불일치: % 벌, 합 %', v_n, v_before;
    end if;

    update public.purchase_batch_items bi
       set initial_price = i.price
      from public.inventory_items i
     where bi.batch_id = v_batch
       and upper(btrim(i.barcode)) = bi.barcode
       and i.price is distinct from bi.initial_price;

    select sum(initial_price) into v_after
      from public.purchase_batch_items where batch_id = v_batch and not excluded;
    select sum(i.price) into v_cur
      from public.purchase_batch_items bi
      join public.inventory_items i on upper(btrim(i.barcode)) = bi.barcode
     where bi.batch_id = v_batch and not bi.excluded;
    if v_after <> 33208000 or v_after <> v_cur then
        raise exception '정정 후 합 불일치: 최초 %, 현재 %', v_after, v_cur;
    end if;
end $$;
