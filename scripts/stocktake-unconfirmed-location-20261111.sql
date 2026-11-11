-- 재고조사: 고정 위치 '미확인' + 택분실 짝 바코드 입력 폐기
-- 적용: supabase db query --linked -f scripts/stocktake-unconfirmed-location-20261111.sql   (stocktake-missing-flag-20261105.sql, location-kind-20261105.sql 이 먼저 적용돼 있어야 함)
--
-- 설계 결정 (2026-11-11)
--   * 조사에서 안 나온 물건 중 폐기하지 않는 것은 결과 화면에서 고정 위치 '미확인'(kind='temp')으로 옮긴다(정정 이동 세션 → 22:00 승인 → VM 이 DB·엑셀 반영).
--     날짜별 위치(7/2재고조사 …)를 조사 때마다 만들지 않는다. 위치로 집계하는 화면에서 미확인 물건이 원래 매장 숫자에서 빠진다.
--   * 상태는 여전히 in_stock(새 상태 없음). 미확인 표시(missing_since 등)는 '미확인' 위치로 들어갈 때 트리거가 유지한다.
--   * 택분실로 새로 입고한 물건과 짝이 확인된 미스캔은 건마다 새 바코드를 입력해 폐기한다.
--     비고: 원 물건 "택분실로 신규 입고 <새 바코드> 바코드로 잡아 폐기", 새 물건 "원 바코드 <원 바코드>와 교환(택분실 신규 입고)".
--   * 기존 날짜별 위치(7/2재고조사 …)의 재고 물건은 DB 에서만 '미확인'으로 옮긴다(엑셀은 그대로, 이동 세션 없음).

begin;

-- 1) 임시 위치 판별: 날짜+재고조사/재봉합 형태이거나 locations.kind='temp' (화면은 kind 만 읽는다)
create or replace function public.is_pseudo_location(p text) returns boolean
language sql stable set search_path = '' as $fn$
    select coalesce(p ~ '^[0-9][0-9/]*(재고조사|재봉합)$', false)
        or exists (select 1 from public.locations l where l.name = p and l.kind = 'temp')
$fn$;
grant execute on function public.is_pseudo_location(text) to authenticated, service_role;

-- 2) 고정 위치 '미확인' (비활성: 위치 목록·이동 앱에 안 뜨고, 정정 이동의 목적지로만 쓴다)
insert into public.locations (name, is_active, kind) values ('미확인', false, 'temp') on conflict (name) do nothing;

-- 3) 짝 바코드 확인: 입력한 바코드가 DB 에 있는지, 이미 짝이 맺어졌는지(관리자 전용)
create or replace function public.stocktake_swap_lookup(p_barcode text)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_b text := upper(btrim(coalesce(p_barcode, ''))); v_i record;
begin
    perform public.stocktake_require_admin();
    if v_b = '' then return null; end if;
    select i.barcode, i.category, i.price, i.brand, i.product_name, i.status, i.location, i.source, i.note into v_i
      from public.inventory_items i where upper(btrim(i.barcode)) = v_b limit 1;
    if not found then return null; end if;
    return jsonb_build_object('barcode', v_i.barcode, 'category', v_i.category, 'price', v_i.price, 'brand', v_i.brand,
        'product_name', v_i.product_name, 'status', v_i.status, 'location', v_i.location, 'source', v_i.source,
        'paired', coalesce(v_i.note, '') like '%와 교환(택분실 신규 입고)%');
end
$fn$;
revoke all on function public.stocktake_swap_lookup(text) from public, anon;
grant execute on function public.stocktake_swap_lookup(text) to authenticated;

-- 4) 위치 정정/폐기: p_swaps(결과 바코드 → 택분실 새 바코드)를 받아 건마다 비고를 남긴다.
--   location_diff: p_to 없으면 스캔 위치로.  missing_found: p_to 없으면 스캔 위치로(같은 위치면 이동 없이 미확인 표시만 해제).
--   missing: p_to 필수('폐기' = 분실 확정/택분실 교환, '미확인' = 폐기하지 않고 미확인 위치로).
--   p_swaps: {"<결과 바코드>": "<새 바코드>", ...} — missing + '폐기' 일 때만. 새 바코드는 DB 에 있어야 한다.
drop function if exists public.stocktake_apply_moves(uuid, text, text[], text, text);
create or replace function public.stocktake_apply_moves(p_session uuid, p_kind text, p_barcodes text[], p_to text default null, p_note text default null, p_swaps jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_date date; v_sess record; v_sid uuid; v_targets jsonb; v_moved int := 0; v_inplace int := 0; v_n int; v_res text;
        v_sw jsonb := '{}'::jsonb; v_k text; v_v text; v_pre text; v_def text;
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

    -- 택분실 짝 바코드 검증
    if p_swaps is not null and p_swaps <> '{}'::jsonb then
        if jsonb_typeof(p_swaps) <> 'object' or p_kind <> 'missing' or p_to is distinct from '폐기' then
            raise exception '짝 바코드는 미스캔을 폐기할 때만 입력할 수 있어요.' using errcode = 'P0001';
        end if;
        for v_k, v_v in select key, value #>> '{}' from jsonb_each(p_swaps) loop
            v_v := upper(btrim(coalesce(v_v, '')));
            if v_v = '' then continue; end if;
            if v_v = upper(btrim(v_k)) then
                raise exception '% 의 짝 바코드가 자기 자신이에요.', v_k using errcode = 'P0001';
            end if;
            if not exists (select 1 from public.inventory_items i where upper(btrim(i.barcode)) = v_v) then
                raise exception '짝 바코드 % 를 장부에서 찾을 수 없어요.', v_v using errcode = 'P0001';
            end if;
            if exists (select 1 from jsonb_each_text(v_sw) e where e.value = v_v) then
                raise exception '짝 바코드 % 가 두 번 입력됐어요.', v_v using errcode = 'P0001';
            end if;
            v_sw := v_sw || jsonb_build_object(v_k, v_v);
        end loop;
    end if;

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
               'swap', v_sw ->> r.barcode,
               'note', case when v_sw ->> r.barcode is not null then '택분실로 신규 입고 ' || (v_sw ->> r.barcode) || ' 바코드로 잡아 폐기'
                            else nullif(btrim(p_note), '') end)), '[]'::jsonb)
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
        from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, swap text, note text)
    loop
        insert into public.move_sessions (session_date, from_location, to_location, status, created_by, is_correction, correction_reason)
        values ((now() at time zone 'Asia/Seoul')::date, v_sess.from_loc, v_sess.to_loc, 'pending', v_name, true, '재고조사 ' || to_char(v_date, 'YYYY-MM-DD'))
        returning id into v_sid;

        insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
        select v_sid, t.raw, t.product_name, t.category, t.price, t.from_loc, v_name, true, false
        from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, swap text, note text)
        where t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;
        get diagnostics v_n = row_count;
        v_moved := v_moved + v_n;

        update public.stocktake_results r
           set resolution = v_res, resolved_by = v_name, resolved_at = now(), move_session_id = v_sid,
               note = coalesce(t.note, r.note)
          from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, swap text, note text)
         where r.session_id = p_session and r.kind = p_kind and r.barcode = t.barcode
           and t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;

        if v_res = 'disposed' then
            update public.inventory_items i
               set note = case when i.note is null or btrim(i.note) = '' then v_pre || coalesce(t.note, v_def) else i.note || E'\n' || v_pre || coalesce(t.note, v_def) end
              from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, swap text, note text)
             where i.barcode = t.raw and t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;

            -- 짝 바코드(택분실 신규 입고 물건) 쪽에도 교환 기록
            update public.inventory_items i
               set note = case when i.note is null or btrim(i.note) = '' then v_pre || '원 바코드 ' || t.raw || '와 교환(택분실 신규 입고)'
                               else i.note || E'\n' || v_pre || '원 바코드 ' || t.raw || '와 교환(택분실 신규 입고)' end
              from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text, swap text, note text)
             where t.swap is not null and upper(btrim(i.barcode)) = t.swap
               and t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;
        end if;
    end loop;

    return jsonb_build_object('moved', v_moved, 'in_place', v_inplace, 'skipped', greatest(cardinality(p_barcodes) - v_moved - v_inplace, 0));
end
$fn$;
revoke all on function public.stocktake_apply_moves(uuid, text, text[], text, text, jsonb) from public, anon;
grant execute on function public.stocktake_apply_moves(uuid, text, text[], text, text, jsonb) to authenticated;

-- 5) 기존 날짜별 위치(7/2재고조사, 12/30재봉합 …)의 재고 물건 → '미확인' (DB 만, 이동 세션·엑셀 변경 없음)
--    트리거: 임시 위치 → 임시 위치라 미확인 표시(missing_since/missing_from/miss_count)는 그대로 유지된다.
update public.inventory_items
   set location = '미확인'
 where status = 'in_stock' and location ~ '^[0-9][0-9/]*(재고조사|재봉합)$';

commit;
