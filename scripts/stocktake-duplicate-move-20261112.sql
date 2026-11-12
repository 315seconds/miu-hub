-- 재고조사: 목록 제출(재봉합 등)과 실물 스캔이 겹친 "중복 스캔" 중 실물 스캔 위치가 장부 위치와 다른 물건(이동 누락 의심)을 정정할 수 있게 한다.
-- 적용: supabase db query --linked -f scripts/stocktake-duplicate-move-20261112.sql   (stocktake-remove-swap-20261111.sql 이 먼저 적용돼 있어야 함)
--   * stocktake_compute: 중복 결과의 scanned_location = 실물(source='scan') 스캔 위치가 하나뿐이면 그 위치(여러 곳이면 NULL, 목록만 겹치면 첫 위치),
--     detail 에 "실물 스캔 위치(X)가 장부 위치와 달라요 — 이동 누락 의심" 표시.
--   * stocktake_apply_moves: p_kind='duplicate' 허용(p_to 없이, 실물 스캔 위치로. 위치가 같거나 NULL 이면 건너뜀).
--   * 이미 닫힌 조사의 중복 결과 행도 같은 기준으로 갱신(resolution 은 그대로).
begin;
CREATE OR REPLACE FUNCTION public.stocktake_compute(p_session uuid)
 RETURNS TABLE(barcode text, kind text, item_barcode text, ledger_location text, scanned_location text, category text, price integer, brand text, product_name text, scan_count integer, scanners text, hangers text, detail text, prior_missing boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
    with agg as (
        select s.barcode,
               count(*)::int as n,
               array_agg(distinct s.location order by s.location) as locs,
               string_agg(distinct s.scanned_by, ', ') as who,
               string_agg(distinct s.hanger_no::text, ', ') as hg,
               bool_and(s.source = 'list') as listed_only,
               array_agg(distinct s.location order by s.location) filter (where s.source = 'scan') as plocs
        from public.stocktake_scans s
        where s.session_id = p_session and s.voided_at is null
        group by s.barcode
    ),
    exp as (
        select * from public.stocktake_expected where session_id = p_session
    ),
    cur as (
        select distinct on (upper(btrim(i.barcode)))
               upper(btrim(i.barcode)) as bk, i.barcode as raw, i.status, i.location, i.category, i.price, i.brand, i.product_name
        from public.inventory_items i
        where upper(btrim(i.barcode)) in (select a.barcode from agg a union select e.barcode from exp e)
        order by upper(btrim(i.barcode)), (i.status = 'in_stock') desc
    ),
    scanned as (
        select a.barcode, a.n, a.locs, a.who, a.hg, a.listed_only,
               e.location as e_loc, e.db_location as e_db, e.was_missing as e_wm,
               e.item_barcode as e_raw, e.category as e_cat, e.price as e_price, e.brand as e_brand, e.product_name as e_pn,
               c.status as c_status, c.location as c_loc, c.raw as c_raw, c.category as c_cat, c.price as c_price, c.brand as c_brand, c.product_name as c_pn,
               (e.barcode is not null) as has_e, (c.bk is not null) as has_c
        from agg a
        left join exp e on e.barcode = a.barcode
        left join cur c on c.bk = a.barcode
    ),
    classified as (
        select sc.*,
            case
                when sc.has_e and sc.e_wm then 'missing_found'
                when sc.has_e and sc.e_loc = any (sc.locs) then 'ok'
                when sc.has_e and sc.c_loc = any (sc.locs) and sc.c_status = 'in_stock' then 'changed'
                when sc.has_e then 'location_diff'
                when not sc.has_c then 'unknown'
                when sc.c_status = 'sold' then 'sold_scanned'
                when sc.c_status = 'disposed' then 'disposed_scanned'
                when sc.c_loc = any (sc.locs) then 'ok'
                else 'location_diff'
            end as k
        from scanned sc
    )
    select cl.barcode, cl.k, coalesce(cl.e_raw, cl.c_raw), coalesce(cl.e_db, cl.c_loc), cl.locs[1],
           coalesce(cl.e_cat, cl.c_cat), coalesce(cl.e_price, cl.c_price), coalesce(cl.e_brand, cl.c_brand), coalesce(cl.e_pn, cl.c_pn),
           cl.n, cl.who, cl.hg,
           coalesce(case cl.k when 'changed' then '조사 중 이동 — 지금 장부 위치가 스캔 위치와 같음' else null end,
                    case when cl.listed_only then '목록 제출 기준 (실물 확인 안 됨)' end),
           coalesce(cl.e_wm, false)
    from classified cl where cl.k <> 'ok'
    union all
    select a.barcode, 'duplicate', coalesce(e.item_barcode, c.raw), coalesce(e.db_location, c.location),
           case when a.plocs is null then a.locs[1] when cardinality(a.plocs) = 1 then a.plocs[1] else null end,
           coalesce(e.category, c.category), coalesce(e.price, c.price), coalesce(e.brand, c.brand), coalesce(e.product_name, c.product_name),
           a.n, a.who, a.hg,
           case when cardinality(a.plocs) = 1 and a.plocs[1] is distinct from coalesce(e.db_location, c.location)
                then '실물 스캔 위치(' || a.plocs[1] || ')가 장부 위치와 달라요 — 이동 누락 의심'
                when cardinality(a.plocs) >= 2 then '서로 다른 위치에서 실물 스캔됨 (' || array_to_string(a.plocs, ', ') || ')'
                end, false
    from agg a left join exp e on e.barcode = a.barcode left join cur c on c.bk = a.barcode
    where a.n >= 2
    union all
    select e.barcode,
           case when c.bk is null or c.status <> 'in_stock' or c.location <> e.db_location then 'changed' else 'missing' end,
           e.item_barcode, e.db_location, null, e.category, e.price, e.brand, e.product_name, 0, null, null,
           case
               when c.bk is null then '조사 중 장부에서 사라짐'
               when c.status = 'sold' then '조사 중 판매됨'
               when c.status = 'disposed' then '조사 중 폐기됨'
               when c.location <> e.db_location then '조사 중 이동 (' || c.location || ')'
               else null
           end,
           e.was_missing
    from exp e
    join public.stocktake_locations l on l.session_id = p_session and l.location = e.location and l.state = 'done'
    left join cur c on c.bk = e.barcode
    where not exists (select 1 from agg a where a.barcode = e.barcode)
$function$;

create or replace function public.stocktake_apply_moves(p_session uuid, p_kind text, p_barcodes text[], p_to text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_date date; v_sess record; v_sid uuid; v_targets jsonb; v_moved int := 0; v_inplace int := 0; v_n int; v_res text;
        v_pre text; v_def text;
begin
    perform public.stocktake_require_admin();
    v_name := public.stocktake_login_name();
    if p_kind not in ('location_diff', 'missing', 'missing_found', 'duplicate') then
        raise exception '이 종류는 위치를 정정할 수 없어요.' using errcode = 'P0001';
    end if;
    if p_kind = 'duplicate' and coalesce(btrim(p_to), '') <> '' then
        raise exception '중복 스캔은 실물 스캔 위치로만 정정할 수 있어요.' using errcode = 'P0001';
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

-- 닫힌 조사의 기존 중복 결과 행 갱신
update public.stocktake_results r
   set scanned_location = p.loc,
       detail = case when p.cnt = 1 and p.loc is distinct from r.ledger_location then '실물 스캔 위치(' || p.loc || ')가 장부 위치와 달라요 — 이동 누락 의심'
                     when p.cnt >= 2 then '서로 다른 위치에서 실물 스캔됨 (' || p.locs || ')' end
  from (
        select s.session_id, s.barcode, count(distinct s.location) cnt, min(s.location) loc, string_agg(distinct s.location, ', ') locs
          from public.stocktake_scans s where s.voided_at is null and s.source = 'scan' group by 1, 2
       ) p
 where r.kind = 'duplicate' and p.session_id = r.session_id and p.barcode = r.barcode
   and exists (select 1 from public.stocktake_sessions z where z.id = r.session_id and z.status = 'closed');
-- 실물 스캔 위치가 여러 곳이면 정정 대상에서 빼기 위해 NULL
update public.stocktake_results r set scanned_location = null
  from (select s.session_id, s.barcode from public.stocktake_scans s where s.voided_at is null and s.source = 'scan' group by 1, 2 having count(distinct s.location) >= 2) p
 where r.kind = 'duplicate' and p.session_id = r.session_id and p.barcode = r.barcode;

commit;
