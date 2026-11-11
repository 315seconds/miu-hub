-- 재고조사: 택분실 짝 바코드 폐기 기능 제거 (2026-11-11 사용자 결정: 추측 매칭은 100% 확실하지 않아 위험하다)
-- 적용: supabase db query --linked -f scripts/stocktake-remove-swap-20261111.sql   (stocktake-unconfirmed-location-20261111.sql 이 먼저 적용돼 있어야 함)
--   stocktake_swap_lookup 삭제, stocktake_apply_moves 에서 p_swaps(건별 짝 바코드·짝 물건 note) 제거. 미확인 위치 이동·폐기는 그대로.
begin;
drop function if exists public.stocktake_swap_lookup(text);
drop function if exists public.stocktake_apply_moves(uuid, text, text[], text, text, jsonb);
create or replace function public.stocktake_apply_moves(p_session uuid, p_kind text, p_barcodes text[], p_to text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_date date; v_sess record; v_sid uuid; v_targets jsonb; v_moved int := 0; v_inplace int := 0; v_n int; v_res text;
        v_pre text; v_def text;
begin
    perform public.stocktake_require_admin();
    v_name := public.stocktake_login_name();
    if p_kind not in ('location_diff', 'missing', 'missing_found') then
        raise exception '이 종류는 위치를 정정할 수 없어요.' using errcode = 'P0001';
    end if;
    if p_kind = 'missing' and coalesce(btrim(p_to), '') = '' then
        raise exception '미스캔 물건은 이동할 위치를 지정해 주세요.' using errcode = 'P0001';
    end if;
    if p_to is not null and not exists (select 1 from public.locations where name = p_to) then
        raise exception '없는 위치예요.' using errcode = 'P0001';
    end if;
    select session_date into v_date from public.stocktake_sessions where id = p_session and status = 'closed';
    if v_date is null then
        raise exception '닫힌 재고조사의 결과만 처리할 수 있어요.' using errcode = 'P0001';
    end if;
    v_res := case when p_to in ('폐기', '위탁종료') then 'disposed' else 'moved' end;
    v_pre := '[재고조사 ' || to_char(v_date, 'YYYY-MM-DD') || '] ';
    v_def := case when v_res = 'disposed' then '분실 확정' when p_kind = 'missing' then '미확인 위치로 이동' else '위치 정정' end;

    -- 미확인 물건을 발견한 위치가 장부 위치와 같으면 이동 없이 표시만 해제
    if p_kind = 'missing_found' then
        with t as (
            select r.barcode, r.item_barcode from public.stocktake_results r
            join public.inventory_items i on i.barcode = r.item_barcode and i.status = 'in_stock' and i.location = r.scanned_location
            where r.session_id = p_session and r.kind = p_kind and r.barcode = any (p_barcodes)
              and r.resolution in ('open', 'found', 'lost', 'ignored') and coalesce(btrim(p_to), '') = ''
        ), u as (
            update public.inventory_items i set missing_since = null, missing_from = null, missing_session_id = null, miss_count = 0
              from t where i.barcode = t.item_barcode returning 1
        )
        update public.stocktake_results r set resolution = 'found', resolved_by = v_name, resolved_at = now()
          from t where r.session_id = p_session and r.kind = p_kind and r.barcode = t.barcode;
        get diagnostics v_inplace = row_count;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
               'barcode', r.barcode, 'raw', r.item_barcode, 'from_loc', r.ledger_location,
               'to_loc', coalesce(nullif(btrim(p_to), ''), r.scanned_location),
               'product_name', coalesce(i.product_name, ''), 'category', coalesce(r.category, ''), 'price', coalesce(r.price::text, ''),
               'note', nullif(btrim(p_note), ''))), '[]'::jsonb)
      into v_targets
    from public.stocktake_results r
    join public.inventory_items i on i.barcode = r.item_barcode and i.status = 'in_stock' and i.location = r.ledger_location
    where r.session_id = p_session and r.kind = p_kind and r.barcode = any (p_barcodes)
      and r.resolution in ('open', 'found', 'lost', 'ignored')
      and r.ledger_location is not null
      and coalesce(nullif(btrim(p_to), ''), r.scanned_location) is not null
      and coalesce(nullif(btrim(p_to), ''), r.scanned_location) <> r.ledger_location;

    for v_sess in
        select distinct t.from_loc, t.to_loc
        from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, note text)
    loop
        insert into public.move_sessions (session_date, from_location, to_location, status, created_by, is_correction, correction_reason)
        values ((now() at time zone 'Asia/Seoul')::date, v_sess.from_loc, v_sess.to_loc, 'pending', v_name, true, '재고조사 ' || to_char(v_date, 'YYYY-MM-DD'))
        returning id into v_sid;

        insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
        select v_sid, t.raw, t.product_name, t.category, t.price, t.from_loc, v_name, true, false
        from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, note text)
        where t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;
        get diagnostics v_n = row_count;
        v_moved := v_moved + v_n;

        update public.stocktake_results r
           set resolution = v_res, resolved_by = v_name, resolved_at = now(), move_session_id = v_sid,
               note = coalesce(t.note, r.note)
          from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, note text)
         where r.session_id = p_session and r.kind = p_kind and r.barcode = t.barcode
           and t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;

        if v_res = 'disposed' then
            update public.inventory_items i
               set note = case when i.note is null or btrim(i.note) = '' then v_pre || coalesce(t.note, v_def) else i.note || E'\n' || v_pre || coalesce(t.note, v_def) end
              from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, note text)
             where i.barcode = t.raw and t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;
        end if;
    end loop;

    return jsonb_build_object('moved', v_moved, 'in_place', v_inplace, 'skipped', greatest(cardinality(p_barcodes) - v_moved - v_inplace, 0));
end
$fn$;
revoke all on function public.stocktake_apply_moves(uuid, text, text[], text, text) from public, anon;
grant execute on function public.stocktake_apply_moves(uuid, text, text[], text, text) to authenticated;

commit;
