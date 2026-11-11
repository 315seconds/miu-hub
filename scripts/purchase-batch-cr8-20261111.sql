-- 유어스업 8차(CR8) 생성 + 2026-11-09 입고 모자 편입 (일회성, 2026-11-11)
--   차시 없이 입고돼 점검 탭 "차시 미배정"에 쌓인 물건을 새 차시에 담는다.
--   사입 통계 화면의 "차시 추가"와 같은 모양: 의류 CR8 + 잡화 CR8_E 두 행(의류는 물건·총액 없음).
--   모자는 purchase_item_kind()로 잡화이므로 CR8_E에 담는다. 가격 수정 이력이 없어 현재가 = 입고 직후 가격이므로 그대로 최초 프라이싱으로 쓴다.
--   사입 총액 454,000원은 잡화 차시(CR8_E)에 기록한다. 8차에서 차시를 아직 끝내지 않는다(수선 중인 물건이 돌아오면 같은 차시에 입고).
-- 안전장치: 대상이 83개·가격 합 3,846,000이 아니면 예외로 전체 취소.

do $$
declare
    v_src uuid; v_e uuid; v_n integer; v_sum bigint;
begin
    select id into v_src from public.sources where name = '유어스업' and is_purchase;
    if v_src is null then raise exception '유어스업 출처 없음'; end if;
    if exists (select 1 from public.purchase_batches where code in ('CR8', 'CR8_E')) then
        raise exception 'CR8 차시가 이미 있음';
    end if;

    insert into public.purchase_batches (source_id, code, round_code, kind, received_from, vat_included, status)
    values (v_src, 'CR8',   'CR8', '의류', date '2026-11-09', true, 'open'),
           (v_src, 'CR8_E', 'CR8', '잡화', date '2026-11-09', true, 'open');
    select id into v_e from public.purchase_batches where code = 'CR8_E';
    insert into public.purchase_batch_costs (batch_id, total_cost) values (v_e, 454000);

    create temp table _cr8 on commit drop as
    select distinct on (upper(btrim(i.barcode))) upper(btrim(i.barcode)) as barcode, coalesce(i.price, 0) as price, i.category
      from public.inventory_items i
     where i.source = '유어스업'
       and i.created_at >= timestamptz '2026-11-09 00:00:00+09'
       and public.purchase_item_kind(i.category) = '잡화'
       and not exists (select 1 from public.purchase_batch_items b where b.barcode = upper(btrim(i.barcode)))
     order by upper(btrim(i.barcode)), i.created_at;
    select count(*), sum(price) into v_n, v_sum from _cr8;
    if v_n <> 83 or v_sum <> 3846000 then
        raise exception '대상 불일치: % 개, 가격 합 %', v_n, v_sum;
    end if;

    insert into public.purchase_batch_items (barcode, batch_id, initial_price, category)
    select barcode, v_e, price, category from _cr8;
end $$;
