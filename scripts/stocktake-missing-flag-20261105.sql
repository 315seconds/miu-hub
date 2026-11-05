-- 재고조사 v2 후속: "미확인(missing)" 표시 + 스캔 없이 마감하는 가상 위치 + 목록 제출 + 최종 위치(위탁종료)
-- 적용: supabase db query --linked -f scripts/stocktake-missing-flag-20261105.sql   (stocktake-v2-20261104.sql 이 먼저 적용돼 있어야 함)
--
-- 설계 결정 (2026-11-05)
--   * 미확인은 상태가 아니라 표시다: inventory_items.status 는 in_stock 그대로, missing_since 가 있으면 "조사에서 안 나온 물건".
--     → 재고를 세는 모든 화면·사입 통계가 그대로 동작하고(재고에서 빠지지 않음), status CHECK 도 건드리지 않는다.
--   * 확정(분실)은 폐기로 보낸다(별도 lost 상태 없음). 폐기/위탁종료로 가면 트리거가 status=disposed 로 바꾸고 미확인 표시는 지워진다.
--   * 위치가 날짜+재고조사/재봉합 형태(예: 7/2재고조사)면 트리거가 미확인으로 표시한다(엑셀·이동 어느 경로로 들어와도 동일).
--   * 위치가 바뀌면(이동·정정) 미확인 표시는 지워진다. 다만 새 위치도 날짜+재고조사 형태면 유지.
--   * 조사 시작 시 미확인 물건 전체가 가상 위치 '미확인 물건' 한 그룹으로 기대 목록에 들어가 어디서든 발견되면 missing_found 로 나온다.
--   * 철수한(비활성) 위치는 스캔할 수 없으므로 가상 위치(virtual): 닫을 때 자동 마감. 다른 곳에서 스캔되면 위치 다름, 안 나오면 미스캔.
--   * 재봉합 같은 곳은 관리자가 바코드 목록을 일괄 제출(source='list'): 실물 확인이 아니므로 결과에 따로 표시.

begin;

-- 1) 컬럼
alter table public.inventory_items
    add column if not exists note               text,
    add column if not exists missing_since      date,
    add column if not exists missing_from       text,
    add column if not exists missing_session_id uuid,
    add column if not exists miss_count         integer not null default 0;

alter table public.stocktake_locations add column if not exists virtual  boolean not null default false;
alter table public.stocktake_expected  add column if not exists db_location text;
alter table public.stocktake_expected  add column if not exists was_missing boolean not null default false;
alter table public.stocktake_scans     add column if not exists source text not null default 'scan';
alter table public.stocktake_scans     drop constraint if exists stocktake_scans_source_check;
alter table public.stocktake_scans     add constraint stocktake_scans_source_check check (source in ('scan', 'list'));
alter table public.stocktake_results   drop constraint if exists stocktake_results_kind_check;
alter table public.stocktake_results   add constraint stocktake_results_kind_check
    check (kind in ('location_diff', 'missing', 'missing_found', 'unknown', 'sold_scanned', 'disposed_scanned', 'changed', 'duplicate'));

create index if not exists inventory_items_missing_idx on public.inventory_items (missing_since) where missing_since is not null;

-- 2) 날짜+재고조사/재봉합 형태의 임시 위치 판별
create or replace function public.is_pseudo_location(p text) returns boolean
language sql immutable set search_path = '' as $fn$
    select coalesce(p ~ '^[0-9][0-9/]*(재고조사|재봉합)$', false)
$fn$;
grant execute on function public.is_pseudo_location(text) to authenticated, service_role;

-- 3) 위치·상태 트리거: 최종 위치(폐기·위탁종료) → disposed, 임시 위치 → 미확인 표시, 위치 변경 → 표시 해제
create or replace function public.inventory_items_sync_disposed()
returns trigger language plpgsql set search_path = 'public' as $fn$
declare v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
    -- 최종 위치
    if new.location in ('폐기', '위탁종료') then
        if new.status = 'in_stock' then new.status := 'disposed'; end if;
    elsif tg_op = 'UPDATE' and old.location in ('폐기', '위탁종료') and new.status = 'disposed' then
        new.status := 'in_stock';   -- 최종 위치에서 나감
    end if;

    -- 미확인 표시
    if tg_op = 'INSERT' then
        if public.is_pseudo_location(new.location) and new.status = 'in_stock' and new.missing_since is null then
            new.missing_since := v_today;
            new.miss_count := greatest(new.miss_count, 1);
        end if;
    elsif new.location is distinct from old.location then
        if public.is_pseudo_location(new.location) and new.status = 'in_stock' then
            new.missing_since := coalesce(new.missing_since, v_today);
            new.miss_count := greatest(new.miss_count, 1);
            if not public.is_pseudo_location(old.location) then
                new.missing_from := coalesce(new.missing_from, old.location);
            end if;
        else
            new.missing_since := null; new.missing_from := null; new.missing_session_id := null; new.miss_count := 0;
        end if;
    end if;
    if new.status <> 'in_stock' then
        new.missing_since := null; new.missing_from := null; new.missing_session_id := null; new.miss_count := 0;
    end if;
    return new;
end $fn$;

-- 4) 결과 계산: 미확인 물건 발견(missing_found), 목록 제출 표시, 가상 위치 반영
create or replace function public.stocktake_compute(p_session uuid)
returns table (
    barcode text, kind text, item_barcode text, ledger_location text, scanned_location text,
    category text, price integer, brand text, product_name text,
    scan_count integer, scanners text, hangers text, detail text, prior_missing boolean
)
language sql stable security definer set search_path = '' as $fn$
    with agg as (
        select s.barcode,
               count(*)::int as n,
               array_agg(distinct s.location order by s.location) as locs,
               string_agg(distinct s.scanned_by, ', ') as who,
               string_agg(distinct s.hanger_no::text, ', ') as hg,
               bool_and(s.source = 'list') as listed_only
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
    select a.barcode, 'duplicate', coalesce(e.item_barcode, c.raw), coalesce(e.db_location, c.location), a.locs[1],
           coalesce(e.category, c.category), coalesce(e.price, c.price), coalesce(e.brand, c.brand), coalesce(e.product_name, c.product_name),
           a.n, a.who, a.hg, null, false
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
$fn$;

-- 5) 시작: 미확인 물건 전체 → 가상 위치 '미확인 물건', 비활성(철수) 위치 → 가상 위치
create or replace function public.stocktake_start(p_locations text[], p_note text default null)
returns uuid language plpgsql security definer set search_path = '' as $fn$
declare v_id uuid; v_name text; v_flagged int;
begin
    perform public.stocktake_require_admin();
    v_name := public.stocktake_login_name();
    if p_locations is null or cardinality(p_locations) = 0 then
        raise exception '조사할 위치를 하나 이상 골라 주세요.' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.stocktake_sessions where status = 'in_progress') then
        raise exception '이미 진행 중인 재고조사가 있어요.' using errcode = 'P0001', hint = 'ACTIVE_EXISTS';
    end if;
    if exists (select 1 from unnest(p_locations) x where not exists (select 1 from public.locations l where l.name = x)) then
        raise exception '없는 위치가 들어 있어요.' using errcode = 'P0001';
    end if;

    insert into public.stocktake_sessions (session_date, started_by, note)
    values ((now() at time zone 'Asia/Seoul')::date, v_name, nullif(btrim(p_note), ''))
    returning id into v_id;

    -- 미확인 물건: 위치와 상관없이 한 그룹
    insert into public.stocktake_expected (session_id, barcode, item_barcode, location, category, price, brand, product_name, db_location, was_missing)
    select distinct on (upper(btrim(i.barcode))) v_id, upper(btrim(i.barcode)), i.barcode, '미확인 물건', i.category, i.price, i.brand, i.product_name, i.location, true
    from public.inventory_items i
    where i.status = 'in_stock' and i.missing_since is not null and btrim(coalesce(i.barcode, '')) <> ''
    order by upper(btrim(i.barcode)), i.created_at;
    get diagnostics v_flagged = row_count;

    insert into public.stocktake_expected (session_id, barcode, item_barcode, location, category, price, brand, product_name, db_location, was_missing)
    select distinct on (upper(btrim(i.barcode))) v_id, upper(btrim(i.barcode)), i.barcode, i.location, i.category, i.price, i.brand, i.product_name, i.location, false
    from public.inventory_items i
    where i.status = 'in_stock' and i.location = any (p_locations) and btrim(coalesce(i.barcode, '')) <> ''
    order by upper(btrim(i.barcode)), i.created_at
    on conflict (session_id, barcode) do nothing;

    insert into public.stocktake_locations (session_id, location, expected_count, virtual)
    select v_id, x, (select count(*) from public.stocktake_expected e where e.session_id = v_id and e.location = x),
           coalesce((select not l.is_active from public.locations l where l.name = x), false)
    from unnest(p_locations) x;
    if v_flagged > 0 then
        insert into public.stocktake_locations (session_id, location, expected_count, virtual) values (v_id, '미확인 물건', v_flagged, true);
    end if;

    analyze public.stocktake_expected;
    return v_id;
end
$fn$;

-- 6) 스캔 전송: 가상 위치로는 스캔할 수 없다
create or replace function public.stocktake_scan_batch(p_session uuid, p_location text, p_scans jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_uid uuid := auth.uid(); v_name text; v_state text; v_virtual boolean; v_status text; v_saved int := 0; v_total int;
begin
    perform public.stocktake_require_user();
    v_name := public.stocktake_login_name();
    if jsonb_typeof(p_scans) is distinct from 'array' then
        raise exception '스캔 목록 형식이 올바르지 않아요.' using errcode = 'P0001';
    end if;
    v_total := jsonb_array_length(p_scans);
    if v_total = 0 then return jsonb_build_object('saved', 0, 'sent', 0); end if;
    if v_total > 1000 then
        raise exception '한 번에 1000건까지만 보낼 수 있어요.' using errcode = 'P0001';
    end if;

    select s.status into v_status from public.stocktake_sessions s where s.id = p_session;
    if v_status is distinct from 'in_progress' then
        raise exception '이 재고조사는 이미 끝났거나 없어요.' using errcode = 'P0001', hint = 'SESSION_CLOSED';
    end if;
    select l.state, l.virtual into v_state, v_virtual from public.stocktake_locations l where l.session_id = p_session and l.location = p_location;
    if v_state is null or v_virtual then
        raise exception '이 위치로는 스캔할 수 없어요.' using errcode = 'P0001', hint = 'BAD_LOCATION';
    end if;
    if v_state <> 'open' then
        raise exception '"%"는 이미 마감된 위치예요. 다시 열어야 스캔을 보낼 수 있어요.', p_location using errcode = 'P0001', hint = 'LOCATION_DONE';
    end if;

    insert into public.stocktake_scans (id, session_id, location, barcode, hanger_no, scanned_by_id, scanned_by, scanned_at)
    select (x->>'id')::uuid, p_session, p_location, upper(btrim(x->>'barcode')),
           nullif(x->>'hanger', '')::int, v_uid, v_name,
           case when nullif(x->>'at', '') is not null
                     and (x->>'at')::timestamptz between now() - interval '2 days' and now() + interval '5 minutes'
                then (x->>'at')::timestamptz else now() end
    from jsonb_array_elements(p_scans) x
    where btrim(coalesce(x->>'barcode', '')) <> '' and length(btrim(x->>'barcode')) <= 60
    on conflict (id) do nothing;
    get diagnostics v_saved = row_count;

    return jsonb_build_object('saved', v_saved, 'sent', v_total);
end
$fn$;

-- 7) 관리자: 바코드 목록 제출 (예: 재봉합 봉투 리스트). 실물 확인이 아니므로 source='list' 로 구분한다.
create or replace function public.stocktake_scan_list(p_session uuid, p_location text, p_barcodes text[])
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_state text; v_virtual boolean; v_status text; v_saved int; v_sent int;
begin
    perform public.stocktake_require_admin();
    v_name := public.stocktake_login_name();
    if p_barcodes is null or cardinality(p_barcodes) = 0 then
        raise exception '바코드 목록이 비어 있어요.' using errcode = 'P0001';
    end if;
    if cardinality(p_barcodes) > 5000 then
        raise exception '한 번에 5000개까지만 제출할 수 있어요.' using errcode = 'P0001';
    end if;
    select s.status into v_status from public.stocktake_sessions s where s.id = p_session;
    if v_status is distinct from 'in_progress' then
        raise exception '이 재고조사는 이미 끝났거나 없어요.' using errcode = 'P0001', hint = 'SESSION_CLOSED';
    end if;
    select l.state, l.virtual into v_state, v_virtual from public.stocktake_locations l where l.session_id = p_session and l.location = p_location;
    if v_state is null or v_virtual then
        raise exception '이 위치로는 목록을 제출할 수 없어요.' using errcode = 'P0001', hint = 'BAD_LOCATION';
    end if;
    if v_state <> 'open' then
        raise exception '"%"는 이미 마감된 위치예요. 다시 열어야 해요.', p_location using errcode = 'P0001', hint = 'LOCATION_DONE';
    end if;
    select count(distinct upper(btrim(b))) into v_sent from unnest(p_barcodes) b where btrim(b) <> '';

    insert into public.stocktake_scans (id, session_id, location, barcode, hanger_no, scanned_by_id, scanned_by, scanned_at, source)
    select gen_random_uuid(), p_session, p_location, z.b, null, auth.uid(), v_name, now(), 'list'
    from (select distinct upper(btrim(x)) as b from unnest(p_barcodes) x) z
    where z.b <> '' and length(z.b) <= 60
      and not exists (select 1 from public.stocktake_scans s where s.session_id = p_session and s.location = p_location and s.barcode = z.b and s.voided_at is null);
    get diagnostics v_saved = row_count;
    return jsonb_build_object('saved', v_saved, 'sent', v_sent, 'already', v_sent - v_saved);
end
$fn$;

-- 8) 닫기: 가상 위치 자동 마감 → 결과 저장 → 안 나온 물건(missing)에 미확인 표시
create or replace function public.stocktake_close(p_session uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_date date; v_open int; v_done int; v_scans int; v_rows int; v_flagged int;
begin
    perform public.stocktake_require_admin();
    perform public.stocktake_refresh_stats();
    v_name := public.stocktake_login_name();
    select session_date into v_date from public.stocktake_sessions where id = p_session and status = 'in_progress' for update;
    if not found then
        raise exception '진행 중인 세션이 아니에요.' using errcode = 'P0001', hint = 'SESSION_CLOSED';
    end if;
    update public.stocktake_locations set state = 'done', done_by = v_name, done_at = now()
     where session_id = p_session and virtual and state = 'open';
    select count(*) filter (where state = 'open'), count(*) filter (where state = 'done' and not virtual) into v_open, v_done
      from public.stocktake_locations where session_id = p_session;
    if v_open > 0 then
        raise exception '마감하지 않은 위치가 % 곳 남아 있어요. 조사를 마치거나 건너뜀 처리해 주세요.', v_open using errcode = 'P0001', hint = 'OPEN_LOCATIONS';
    end if;
    if v_done = 0 then
        raise exception '마감한 위치가 하나도 없어요.' using errcode = 'P0001', hint = 'NO_DONE';
    end if;
    select count(*) into v_scans from public.stocktake_scans where session_id = p_session and voided_at is null;
    if v_scans = 0 then
        raise exception '스캔 기록이 없어요.' using errcode = 'P0001', hint = 'NO_SCANS';
    end if;

    insert into public.stocktake_results (session_id, barcode, kind, item_barcode, ledger_location, scanned_location, category, price, brand, product_name, scan_count, scanners, hangers, detail, prior_missing)
    select p_session, c.barcode, c.kind, c.item_barcode, c.ledger_location, c.scanned_location, c.category, c.price, c.brand, c.product_name, c.scan_count, c.scanners, c.hangers, c.detail, c.prior_missing
    from public.stocktake_compute(p_session) c;
    get diagnostics v_rows = row_count;

    -- 안 나온 물건 = 미확인 표시(위치·상태는 그대로)
    update public.inventory_items i
       set missing_since      = coalesce(i.missing_since, v_date),
           missing_session_id = coalesce(i.missing_session_id, p_session),
           missing_from       = coalesce(i.missing_from, case when public.is_pseudo_location(i.location) then null else i.location end),
           miss_count         = i.miss_count + 1
      from public.stocktake_results r
     where r.session_id = p_session and r.kind = 'missing' and i.barcode = r.item_barcode and i.status = 'in_stock';
    get diagnostics v_flagged = row_count;

    update public.stocktake_sessions set status = 'closed', closed_by = v_name, closed_at = now() where id = p_session;
    return jsonb_build_object('results', v_rows, 'scans', v_scans, 'flagged', v_flagged);
end
$fn$;

-- 9) 조회 함수: 스캐너용 장부(가상 위치 목록 포함), 위치별 진행(가상 여부·목록 제출 수·어디서든 발견된 수), 요약(목록 제출 수)
create or replace function public.stocktake_ledger(p_session uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_locs text[]; v_virtual text[];
begin
    perform public.stocktake_require_user();
    select array_agg(location order by location) into v_locs from public.stocktake_locations where session_id = p_session;
    select coalesce(array_agg(location order by location), '{}'::text[]) into v_virtual from public.stocktake_locations where session_id = p_session and virtual;
    return jsonb_build_object(
        'locations', to_jsonb(coalesce(v_locs, '{}'::text[])),
        'virtual', to_jsonb(v_virtual),
        'items', coalesce((
            select jsonb_agg(jsonb_build_array(e.barcode, array_position(v_locs, e.location), coalesce(e.category, '')))
            from public.stocktake_expected e where e.session_id = p_session), '[]'::jsonb));
end
$fn$;

create or replace function public.stocktake_progress(p_session uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_user();
    perform public.stocktake_refresh_stats();
    return coalesce((
        select jsonb_agg(row_to_json(t)::jsonb order by t.virtual, t.location)
        from (
            select l.location, l.state, l.virtual, l.expected_count, l.done_by, l.done_at, l.skip_reason,
                   coalesce(a.scanned, 0) as scanned, coalesce(a.ok, 0) as ok, coalesce(a.scanned, 0) - coalesce(a.ok, 0) as other,
                   coalesce(a.dups, 0) as dups, coalesce(a.listed, 0) as listed, coalesce(f.found, 0) as found, a.first_at, a.last_at,
                   coalesce(w.scanners, '{}'::jsonb) as scanners
            from public.stocktake_locations l
            left join (
                select s.location,
                       count(distinct s.barcode) as scanned,
                       count(distinct s.barcode) filter (where e.barcode is not null) as ok,
                       count(*) - count(distinct s.barcode) as dups,
                       count(distinct s.barcode) filter (where s.source = 'list') as listed,
                       min(s.scanned_at) as first_at, max(s.scanned_at) as last_at
                from public.stocktake_scans s
                left join public.stocktake_expected e on e.session_id = s.session_id and e.barcode = s.barcode and e.location = s.location
                where s.session_id = p_session and s.voided_at is null
                group by s.location
            ) a on a.location = l.location
            left join (
                select e.location, count(*) as found
                from public.stocktake_expected e
                where e.session_id = p_session
                  and exists (select 1 from public.stocktake_scans s where s.session_id = p_session and s.barcode = e.barcode and s.voided_at is null)
                group by e.location
            ) f on f.location = l.location
            left join (
                select z.location, jsonb_object_agg(z.scanned_by, z.n) as scanners
                from (select location, scanned_by, count(*) as n from public.stocktake_scans
                      where session_id = p_session and voided_at is null group by location, scanned_by) z
                group by z.location
            ) w on w.location = l.location
            where l.session_id = p_session
        ) t), '[]'::jsonb);
end
$fn$;

create or replace function public.stocktake_summary(p_session uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_status text; v_kinds jsonb; v_ok int; v_scanned int; v_expected int; v_listed int;
begin
    perform public.stocktake_require_user();
    perform public.stocktake_refresh_stats();
    select status into v_status from public.stocktake_sessions where id = p_session;
    if v_status is null then raise exception '없는 세션이에요.' using errcode = 'P0001'; end if;
    if v_status = 'closed' then
        select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) into v_kinds
        from (select kind as k, count(*) as n from public.stocktake_results where session_id = p_session group by kind) z;
    else
        select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) into v_kinds
        from (select c.kind as k, count(*) as n from public.stocktake_compute(p_session) c group by c.kind) z;
    end if;
    select count(*) into v_expected from public.stocktake_expected where session_id = p_session;
    select count(distinct s.barcode), count(distinct s.barcode) filter (where s.source = 'list')
      into v_scanned, v_listed
      from public.stocktake_scans s where s.session_id = p_session and s.voided_at is null;
    select count(distinct s.barcode) into v_ok
      from public.stocktake_scans s join public.stocktake_expected e on e.session_id = s.session_id and e.barcode = s.barcode and e.location = s.location
     where s.session_id = p_session and s.voided_at is null and not e.was_missing;
    return jsonb_build_object('status', v_status, 'expected', v_expected, 'scanned', v_scanned, 'listed', v_listed, 'ok', v_ok, 'kinds', v_kinds);
end
$fn$;

-- 10) 결과 처리
-- 기록만 남기는 처리. 찾음(found)은 missing/missing_found 의 미확인 표시를 지운다(위치는 그대로).
create or replace function public.stocktake_resolve(p_session uuid, p_kind text, p_barcodes text[], p_resolution text, p_note text default null)
returns integer language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
    perform public.stocktake_require_admin();
    if p_resolution not in ('open', 'found', 'ignored') then
        raise exception '이 처리는 여기서 할 수 없어요. (이동·폐기는 위치 정정으로 처리)' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.stocktake_sessions where id = p_session and status = 'closed') then
        raise exception '닫힌 재고조사의 결과만 처리할 수 있어요.' using errcode = 'P0001';
    end if;
    if p_resolution = 'found' and p_kind in ('missing', 'missing_found') then
        update public.inventory_items i
           set missing_since = null, missing_from = null, missing_session_id = null, miss_count = 0
          from public.stocktake_results r
         where r.session_id = p_session and r.kind = p_kind and r.barcode = any (p_barcodes)
           and r.resolution in ('open', 'found', 'ignored') and i.barcode = r.item_barcode and i.status = 'in_stock';
    end if;
    update public.stocktake_results r
       set resolution = p_resolution,
           resolved_by = case when p_resolution = 'open' then null else public.stocktake_login_name() end,
           resolved_at = case when p_resolution = 'open' then null else now() end,
           note = nullif(btrim(p_note), '')
     where r.session_id = p_session and r.kind = p_kind and r.barcode = any (p_barcodes)
       and r.resolution in ('open', 'found', 'lost', 'ignored');
    get diagnostics v_n = row_count;
    return v_n;
end
$fn$;

-- 위치 정정/폐기: 정정 이동 세션 생성(22:00 자동 승인 뒤 VM 이 DB·엑셀 반영).
--   location_diff: p_to 없으면 스캔 위치로.  missing_found: p_to 없으면 스캔 위치로(같은 위치면 이동 없이 미확인 표시만 해제).
--   missing: p_to 필수(보통 '폐기' = 분실 확정). p_note 는 폐기 확정 사유로 inventory_items.note 에 남는다.
drop function if exists public.stocktake_apply_moves(uuid, text, text[], text);
create or replace function public.stocktake_apply_moves(p_session uuid, p_kind text, p_barcodes text[], p_to text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_date date; v_sess record; v_sid uuid; v_targets jsonb; v_moved int := 0; v_inplace int := 0; v_n int; v_res text; v_reason text;
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
    v_reason := '[재고조사 ' || to_char(v_date, 'YYYY-MM-DD') || '] ' || coalesce(nullif(btrim(p_note), ''), case when v_res = 'disposed' then '분실 확정' else '위치 정정' end);

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
               'product_name', coalesce(i.product_name, ''), 'category', coalesce(r.category, ''), 'price', coalesce(r.price::text, ''))), '[]'::jsonb)
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
        from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text)
    loop
        insert into public.move_sessions (session_date, from_location, to_location, status, created_by, is_correction, correction_reason)
        values ((now() at time zone 'Asia/Seoul')::date, v_sess.from_loc, v_sess.to_loc, 'pending', v_name, true, '재고조사 ' || to_char(v_date, 'YYYY-MM-DD'))
        returning id into v_sid;

        insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
        select v_sid, t.raw, t.product_name, t.category, t.price, t.from_loc, v_name, true, false
        from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text)
        where t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc;
        get diagnostics v_n = row_count;
        v_moved := v_moved + v_n;

        update public.stocktake_results r
           set resolution = v_res, resolved_by = v_name, resolved_at = now(), move_session_id = v_sid,
               note = coalesce(nullif(btrim(p_note), ''), r.note)
         where r.session_id = p_session and r.kind = p_kind
           and r.barcode in (
               select t.barcode from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text)
               where t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc);

        if v_res = 'disposed' then
            update public.inventory_items i
               set note = case when i.note is null or btrim(i.note) = '' then v_reason else i.note || E'\n' || v_reason end
             where i.barcode in (
                 select t.raw from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text)
                 where t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc);
        end if;
    end loop;

    return jsonb_build_object('moved', v_moved, 'in_place', v_inplace, 'skipped', greatest(cardinality(p_barcodes) - v_moved - v_inplace, 0));
end
$fn$;

-- 11) 미확인 물건 목록(택분실 교환 대조용 등): 장부에 남은 모든 미확인 물건
create or replace function public.stocktake_missing_candidates()
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_user();
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'barcode', i.barcode, 'category', i.category, 'price', i.price, 'brand', i.brand, 'product_name', i.product_name,
            'photo_url', i.photo_url, 'location', i.location, 'missing_since', i.missing_since, 'missing_from', i.missing_from,
            'miss_count', i.miss_count, 'missing_session_id', i.missing_session_id, 'note', i.note)
            order by i.missing_since, i.barcode)
        from public.inventory_items i where i.status = 'in_stock' and i.missing_since is not null), '[]'::jsonb);
end
$fn$;

-- 12) 실행 권한
revoke all on function
    public.stocktake_scan_list(uuid, text, text[]), public.stocktake_apply_moves(uuid, text, text[], text, text), public.stocktake_missing_candidates()
  from public, anon;
grant execute on function
    public.stocktake_scan_list(uuid, text, text[]), public.stocktake_apply_moves(uuid, text, text[], text, text), public.stocktake_missing_candidates()
  to authenticated;
-- 기존 함수를 create or replace 로 다시 만들면 권한이 유지되지만, 안전하게 다시 지정한다
revoke all on function
    public.stocktake_start(text[], text), public.stocktake_close(uuid), public.stocktake_scan_batch(uuid, text, jsonb),
    public.stocktake_ledger(uuid), public.stocktake_progress(uuid), public.stocktake_summary(uuid), public.stocktake_resolve(uuid, text, text[], text, text)
  from public, anon;
grant execute on function
    public.stocktake_start(text[], text), public.stocktake_close(uuid), public.stocktake_scan_batch(uuid, text, jsonb),
    public.stocktake_ledger(uuid), public.stocktake_progress(uuid), public.stocktake_summary(uuid), public.stocktake_resolve(uuid, text, text[], text, text)
  to authenticated;
revoke all on function public.stocktake_compute(uuid) from public, anon, authenticated;

commit;
