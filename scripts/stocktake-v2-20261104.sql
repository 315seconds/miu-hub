-- 재고조사 전면 개편 (v2)
-- 적용: supabase db query --linked -f scripts/stocktake-v2-20261104.sql
--
-- !! 되돌릴 수 없음: 기존 stocktake_sessions / stocktake_scans(2026-07-02 조사 스캔 33,986건)를 삭제하고 새로 만든다.
--    기존 보고서 버킷(stocktake-reports)은 비공개로 바꾸고 파일은 남긴다.
--
-- 설계 요약
--   세션 시작 = 그 시점 장부(in_stock)를 위치별로 얼려 둔다(stocktake_expected). 완료 시점 변동에 결과가 흔들리지 않는다.
--   스캔 = 클라이언트가 만든 UUID(id)로 멱등 저장. 제출 버튼 없이 자동 전송, 재전송해도 중복되지 않는다.
--   위치(구역) 마감 = 사람이 정한다. 마감한 위치만 미스캔을 판정한다. 모든 위치가 마감/건너뜀이어야 세션을 닫을 수 있다.
--   결과 = 서버 SQL(stocktake_compute)로 계산해 stocktake_results에 저장. 처리 상태(resolution)를 붙여 후속 처리를 추적한다.
--   위치 수정 = 기존 이동 파이프라인 재사용: 정정 이동 세션(move_sessions.is_correction)을 만들면 22:00 자동 승인 뒤 VM이 DB·엑셀에 반영한다.
--   쓰기는 전부 RPC(security definer, 권한 검사 포함). 테이블 직접 쓰기 권한 없음. 담당자 이름은 로그인 이름으로 서버가 고정한다.
--   바코드는 서버에서 upper(btrim()) 정규화한다(inventory_items 장부 바코드는 이미 정규화 상태).

begin;

-- 0) 기존 재고조사 삭제 + 보고서 버킷 비공개화 (공개 URL 차단)
drop table if exists public.stocktake_scans cascade;
drop table if exists public.stocktake_sessions cascade;
drop policy if exists authenticated_select_stocktake_reports on storage.objects;
drop policy if exists authenticated_insert_stocktake_reports on storage.objects;
drop policy if exists authenticated_update_stocktake_reports on storage.objects;
update storage.buckets set public = false where id = 'stocktake-reports';

-- 1) 테이블
create table public.stocktake_sessions (
    id           uuid primary key default gen_random_uuid(),
    session_date date not null,
    status       text not null default 'in_progress' check (status in ('in_progress', 'closed', 'cancelled')),
    note         text,
    started_by   text not null,
    started_at   timestamptz not null default now(),
    closed_by    text,
    closed_at    timestamptz
);
-- 진행 중 세션은 하나만
create unique index stocktake_one_active on public.stocktake_sessions (status) where status = 'in_progress';

create table public.stocktake_locations (
    session_id     uuid not null references public.stocktake_sessions(id) on delete cascade,
    location       text not null,
    expected_count integer not null default 0,
    state          text not null default 'open' check (state in ('open', 'done', 'skipped')),
    done_by        text,
    done_at        timestamptz,
    skip_reason    text,
    primary key (session_id, location)
);

-- 세션 시작 시점 장부 스냅샷 (in_stock만)
create table public.stocktake_expected (
    session_id   uuid not null references public.stocktake_sessions(id) on delete cascade,
    barcode      text not null,            -- 정규화(upper(btrim))
    item_barcode text not null,            -- 장부 원본 바코드(이동 세션에 쓴다)
    location     text not null,
    category     text,
    price        integer,
    brand        text,
    product_name text,
    primary key (session_id, barcode)
);
create index stocktake_expected_loc_idx on public.stocktake_expected (session_id, location);

create table public.stocktake_scans (
    id           uuid primary key,          -- 클라이언트가 만든 UUID = 멱등 키
    session_id   uuid not null references public.stocktake_sessions(id) on delete cascade,
    location     text not null,
    barcode      text not null,             -- 정규화
    hanger_no    integer,
    scanned_by_id uuid not null,
    scanned_by   text not null,
    scanned_at   timestamptz not null,
    received_at  timestamptz not null default now(),
    voided_at    timestamptz,
    voided_by    text
);
create index stocktake_scans_loc_idx on public.stocktake_scans (session_id, location) where voided_at is null;
create index stocktake_scans_bc_idx  on public.stocktake_scans (session_id, barcode) where voided_at is null;

create table public.stocktake_results (
    session_id       uuid not null references public.stocktake_sessions(id) on delete cascade,
    barcode          text not null,
    kind             text not null check (kind in ('location_diff', 'missing', 'unknown', 'sold_scanned', 'disposed_scanned', 'changed', 'duplicate')),
    item_barcode     text,
    ledger_location  text,
    scanned_location text,
    category         text,
    price            integer,
    brand            text,
    product_name     text,
    scan_count       integer not null default 0,
    scanners         text,
    hangers          text,
    detail           text,
    prior_missing    boolean not null default false,   -- 직전 조사에서도 미스캔이었던 물건
    resolution       text not null default 'open' check (resolution in ('open', 'found', 'lost', 'ignored', 'moved', 'disposed')),
    resolved_by      text,
    resolved_at      timestamptz,
    note             text,
    move_session_id  uuid,
    primary key (session_id, barcode, kind)
);
create index stocktake_results_open_idx on public.stocktake_results (resolution) where resolution = 'open';

alter table public.stocktake_sessions  enable row level security;
alter table public.stocktake_locations enable row level security;
alter table public.stocktake_expected  enable row level security;
alter table public.stocktake_scans     enable row level security;
alter table public.stocktake_results   enable row level security;

-- 읽기: 세션·위치·결과만 로그인 직원에게 연다. 스냅샷·스캔은 RPC로만. 쓰기는 전부 RPC.
create policy stocktake_sessions_select  on public.stocktake_sessions  for select to authenticated using (true);
create policy stocktake_locations_select on public.stocktake_locations for select to authenticated using (true);
create policy stocktake_results_select   on public.stocktake_results   for select to authenticated using (true);

revoke all on public.stocktake_sessions, public.stocktake_locations, public.stocktake_expected, public.stocktake_scans, public.stocktake_results from anon, authenticated;
grant select on public.stocktake_sessions, public.stocktake_locations, public.stocktake_results to authenticated;
grant select, insert, update, delete on public.stocktake_sessions, public.stocktake_locations, public.stocktake_expected, public.stocktake_scans, public.stocktake_results to service_role;

-- 2) 내부 도우미
create or replace function public.stocktake_login_name() returns text
language plpgsql stable security definer set search_path = '' as $fn$
declare v_name text;
begin
    select p.name into v_name from public.profiles p where p.id = auth.uid();
    if v_name is null or btrim(v_name) = '' then
        raise exception '계정에 이름이 설정돼 있지 않아요. 관리자에게 요청해 주세요.' using errcode = 'P0001';
    end if;
    return v_name;
end
$fn$;

create or replace function public.stocktake_require_admin() returns void
language plpgsql stable security definer set search_path = '' as $fn$
begin
    if auth.uid() is null or not public.is_admin() then
        raise exception '관리자만 할 수 있어요.' using errcode = '42501';
    end if;
end
$fn$;

create or replace function public.stocktake_require_user() returns void
language plpgsql stable security definer set search_path = '' as $fn$
begin
    if auth.uid() is null then
        raise exception '로그인이 필요해요.' using errcode = '42501';
    end if;
end
$fn$;

-- 통계 갱신: 방금 대량으로 들어온 테이블은 autoanalyze 전에는 통계가 없어 플래너가 엉뚱한 계획(중첩 루프)을 골라
-- 결과 계산이 시간 제한(8초)을 넘길 수 있다. 변경이 많을 때만 그 자리에서 ANALYZE 한다.
create or replace function public.stocktake_refresh_stats() returns void
language plpgsql security definer set search_path = '' as $fn$
begin
    if coalesce((select n_mod_since_analyze from pg_catalog.pg_stat_user_tables where relid = 'public.stocktake_scans'::regclass), 1001) > 1000 then
        analyze public.stocktake_scans;
    end if;
    if coalesce((select n_mod_since_analyze from pg_catalog.pg_stat_user_tables where relid = 'public.stocktake_expected'::regclass), 1001) > 1000 then
        analyze public.stocktake_expected;
    end if;
end
$fn$;

-- 3) 결과 계산 (내부용). 마감(done)한 위치만 미스캔을 판정한다.
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
               string_agg(distinct s.hanger_no::text, ', ') as hg
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
    prev as (
        select r.barcode from public.stocktake_results r
        where r.kind = 'missing' and r.resolution in ('open', 'lost')
          and r.session_id = (
              select ps.id from public.stocktake_sessions ps
              where ps.status = 'closed' and ps.id <> p_session
                and ps.started_at < (select started_at from public.stocktake_sessions where id = p_session)
              order by ps.started_at desc limit 1)
    ),
    scanned as (
        select a.barcode, a.n, a.locs, a.who, a.hg,
               e.location as e_loc, e.item_barcode as e_raw, e.category as e_cat, e.price as e_price, e.brand as e_brand, e.product_name as e_pn,
               c.status as c_status, c.location as c_loc, c.raw as c_raw, c.category as c_cat, c.price as c_price, c.brand as c_brand, c.product_name as c_pn,
               (e.barcode is not null) as has_e, (c.bk is not null) as has_c
        from agg a
        left join exp e on e.barcode = a.barcode
        left join cur c on c.bk = a.barcode
    ),
    classified as (
        select sc.*,
            case
                when sc.has_e and sc.e_loc = any (sc.locs) then 'ok'
                when sc.has_e and sc.c_loc = any (sc.locs) and sc.c_status = 'in_stock' then 'changed'     -- 조사 중 이동해 지금은 스캔 위치와 같음
                when sc.has_e then 'location_diff'
                when not sc.has_c then 'unknown'
                when sc.c_status = 'sold' then 'sold_scanned'
                when sc.c_status = 'disposed' then 'disposed_scanned'
                when sc.c_loc = any (sc.locs) then 'ok'                                                   -- 조사 시작 뒤 입고된 물건
                else 'location_diff'
            end as k
        from scanned sc
    )
    -- 스캔된 바코드
    select cl.barcode, cl.k, coalesce(cl.e_raw, cl.c_raw), coalesce(cl.e_loc, cl.c_loc), cl.locs[1],
           coalesce(cl.e_cat, cl.c_cat), coalesce(cl.e_price, cl.c_price), coalesce(cl.e_brand, cl.c_brand), coalesce(cl.e_pn, cl.c_pn),
           cl.n, cl.who, cl.hg,
           case cl.k when 'changed' then '조사 중 이동 — 지금 장부 위치가 스캔 위치와 같음' else null end,
           exists (select 1 from prev p where p.barcode = cl.barcode)
    from classified cl where cl.k <> 'ok'
    union all
    -- 중복 스캔
    select a.barcode, 'duplicate', coalesce(e.item_barcode, c.raw), coalesce(e.location, c.location), a.locs[1],
           coalesce(e.category, c.category), coalesce(e.price, c.price), coalesce(e.brand, c.brand), coalesce(e.product_name, c.product_name),
           a.n, a.who, a.hg, null, false
    from agg a left join exp e on e.barcode = a.barcode left join cur c on c.bk = a.barcode
    where a.n >= 2
    union all
    -- 마감한 위치의 미스캔
    select e.barcode,
           case when c.bk is null or c.status <> 'in_stock' or c.location <> e.location then 'changed' else 'missing' end,
           e.item_barcode, e.location, null, e.category, e.price, e.brand, e.product_name, 0, null, null,
           case
               when c.bk is null then '조사 중 장부에서 사라짐'
               when c.status = 'sold' then '조사 중 판매됨'
               when c.status = 'disposed' then '조사 중 폐기됨'
               when c.location <> e.location then '조사 중 이동 (' || c.location || ')'
               else null
           end,
           exists (select 1 from prev p where p.barcode = e.barcode)
    from exp e
    join public.stocktake_locations l on l.session_id = p_session and l.location = e.location and l.state = 'done'
    left join cur c on c.bk = e.barcode
    where not exists (select 1 from agg a where a.barcode = e.barcode)
$fn$;

-- 4) 관리자: 시작 / 닫기 / 취소
create or replace function public.stocktake_start(p_locations text[], p_note text default null)
returns uuid language plpgsql security definer set search_path = '' as $fn$
declare v_id uuid; v_name text;
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

    insert into public.stocktake_expected (session_id, barcode, item_barcode, location, category, price, brand, product_name)
    select distinct on (upper(btrim(i.barcode))) v_id, upper(btrim(i.barcode)), i.barcode, i.location, i.category, i.price, i.brand, i.product_name
    from public.inventory_items i
    where i.status = 'in_stock' and i.location = any (p_locations) and btrim(coalesce(i.barcode, '')) <> ''
    order by upper(btrim(i.barcode)), i.created_at;

    insert into public.stocktake_locations (session_id, location, expected_count)
    select v_id, x, (select count(*) from public.stocktake_expected e where e.session_id = v_id and e.location = x)
    from unnest(p_locations) x;

    analyze public.stocktake_expected;
    return v_id;
end
$fn$;

create or replace function public.stocktake_cancel(p_session uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_admin();
    if coalesce(btrim(p_reason), '') = '' then
        raise exception '취소 사유를 적어 주세요.' using errcode = 'P0001';
    end if;
    update public.stocktake_sessions
       set status = 'cancelled', closed_by = public.stocktake_login_name(), closed_at = now(), note = coalesce(note || E'\n', '') || '취소: ' || btrim(p_reason)
     where id = p_session and status = 'in_progress';
    if not found then
        raise exception '진행 중인 세션이 아니에요.' using errcode = 'P0001';
    end if;
end
$fn$;

create or replace function public.stocktake_close(p_session uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_open int; v_done int; v_scans int; v_rows int;
begin
    perform public.stocktake_require_admin();
    perform public.stocktake_refresh_stats();
    v_name := public.stocktake_login_name();
    perform 1 from public.stocktake_sessions where id = p_session and status = 'in_progress' for update;
    if not found then
        raise exception '진행 중인 세션이 아니에요.' using errcode = 'P0001', hint = 'SESSION_CLOSED';
    end if;
    select count(*) filter (where state = 'open'), count(*) filter (where state = 'done') into v_open, v_done
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

    update public.stocktake_sessions set status = 'closed', closed_by = v_name, closed_at = now() where id = p_session;
    return jsonb_build_object('results', v_rows, 'scans', v_scans);
end
$fn$;

-- 5) 직원: 스캔 / 위치 마감
create or replace function public.stocktake_scan_batch(p_session uuid, p_location text, p_scans jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_uid uuid := auth.uid(); v_name text; v_state text; v_status text; v_saved int := 0; v_total int;
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
    select l.state into v_state from public.stocktake_locations l where l.session_id = p_session and l.location = p_location;
    if v_state is null then
        raise exception '이 재고조사에 없는 위치예요.' using errcode = 'P0001', hint = 'BAD_LOCATION';
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

-- 내 스캔 취소(기록은 남김). 위치가 열려 있는 동안만.
create or replace function public.stocktake_scan_void(p_session uuid, p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
    perform public.stocktake_require_user();
    update public.stocktake_scans s
       set voided_at = now(), voided_by = public.stocktake_login_name()
     where s.session_id = p_session and s.id = any (p_ids) and s.voided_at is null
       and (s.scanned_by_id = auth.uid() or public.is_admin())
       and exists (select 1 from public.stocktake_sessions z where z.id = p_session and z.status = 'in_progress')
       and exists (select 1 from public.stocktake_locations l where l.session_id = p_session and l.location = s.location and l.state = 'open');
    get diagnostics v_n = row_count;
    return v_n;
end
$fn$;

-- 위치 상태: done/open은 직원 누구나, skipped는 관리자(사유 필수)
create or replace function public.stocktake_location_set(p_session uuid, p_location text, p_state text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $fn$
declare v_name text;
begin
    perform public.stocktake_require_user();
    v_name := public.stocktake_login_name();
    if p_state not in ('open', 'done', 'skipped') then
        raise exception '상태 값이 올바르지 않아요.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.stocktake_sessions where id = p_session and status = 'in_progress') then
        raise exception '진행 중인 세션이 아니에요.' using errcode = 'P0001', hint = 'SESSION_CLOSED';
    end if;
    if p_state = 'skipped' then
        perform public.stocktake_require_admin();
        if coalesce(btrim(p_reason), '') = '' then
            raise exception '건너뜀 사유를 적어 주세요.' using errcode = 'P0001';
        end if;
    end if;
    if p_state = 'done' and not exists (
        select 1 from public.stocktake_scans where session_id = p_session and location = p_location and voided_at is null
    ) then
        raise exception '스캔한 물건이 없어서 마감할 수 없어요. 이 위치에 물건이 없다면 관리자에게 건너뜀 처리를 요청해 주세요.' using errcode = 'P0001', hint = 'NO_SCANS';
    end if;
    update public.stocktake_locations
       set state = p_state,
           done_by = case when p_state = 'open' then null else v_name end,
           done_at = case when p_state = 'open' then null else now() end,
           skip_reason = case when p_state = 'skipped' then btrim(p_reason) else null end
     where session_id = p_session and location = p_location;
    if not found then
        raise exception '이 재고조사에 없는 위치예요.' using errcode = 'P0001', hint = 'BAD_LOCATION';
    end if;
end
$fn$;

-- 6) 조회
-- 스캐너용 장부 스냅샷: 전체를 한 번에(응답 행 수 제한을 피하려고 jsonb 한 덩어리). items = [바코드, 위치 번호, 카테고리]
create or replace function public.stocktake_ledger(p_session uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_locs text[];
begin
    perform public.stocktake_require_user();
    select array_agg(location order by location) into v_locs from public.stocktake_locations where session_id = p_session;
    return jsonb_build_object(
        'locations', to_jsonb(coalesce(v_locs, '{}'::text[])),
        'items', coalesce((
            select jsonb_agg(jsonb_build_array(e.barcode, array_position(v_locs, e.location), coalesce(e.category, '')))
            from public.stocktake_expected e where e.session_id = p_session), '[]'::jsonb));
end
$fn$;

-- 스냅샷 밖 바코드의 현재 상태 조회(스캐너가 "장부에 없음" 사유를 보여주려고 호출). 최대 200개.
create or replace function public.stocktake_lookup(p_barcodes text[])
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_user();
    if cardinality(p_barcodes) > 200 then
        raise exception '한 번에 200개까지만 조회할 수 있어요.' using errcode = 'P0001';
    end if;
    return coalesce((
        select jsonb_object_agg(x.bk, jsonb_build_object('status', x.status, 'location', x.location, 'category', coalesce(x.category, '')))
        from (
            select distinct on (upper(btrim(i.barcode))) upper(btrim(i.barcode)) as bk, i.status, i.location, i.category
            from public.inventory_items i
            where upper(btrim(i.barcode)) = any (select upper(btrim(b)) from unnest(p_barcodes) b)
            order by upper(btrim(i.barcode)), (i.status = 'in_stock') desc
        ) x), '{}'::jsonb);
end
$fn$;

-- 위치별 진행 현황
create or replace function public.stocktake_progress(p_session uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_user();
    perform public.stocktake_refresh_stats();
    return coalesce((
        select jsonb_agg(row_to_json(t)::jsonb order by t.location)
        from (
            select l.location, l.state, l.expected_count, l.done_by, l.done_at, l.skip_reason,
                   coalesce(a.scanned, 0) as scanned, coalesce(a.ok, 0) as ok, coalesce(a.scanned, 0) - coalesce(a.ok, 0) as other,
                   coalesce(a.dups, 0) as dups, a.first_at, a.last_at,
                   coalesce(w.scanners, '{}'::jsonb) as scanners
            from public.stocktake_locations l
            left join (
                select s.location,
                       count(distinct s.barcode) as scanned,
                       count(distinct s.barcode) filter (where e.barcode is not null) as ok,
                       count(*) - count(distinct s.barcode) as dups,
                       min(s.scanned_at) as first_at, max(s.scanned_at) as last_at
                from public.stocktake_scans s
                left join public.stocktake_expected e on e.session_id = s.session_id and e.barcode = s.barcode and e.location = s.location
                where s.session_id = p_session and s.voided_at is null
                group by s.location
            ) a on a.location = l.location
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

-- 아직 스캔 안 된 장부 물건(위치 마감 전에 찾아보는 용도). 팀 전체 스캔 기준.
create or replace function public.stocktake_unscanned(p_session uuid, p_location text)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_user();
    perform public.stocktake_refresh_stats();
    return coalesce((
        select jsonb_agg(jsonb_build_array(e.barcode, coalesce(e.category, ''), e.price, coalesce(e.brand, ''), coalesce(e.product_name, '')) order by e.category, e.barcode)
        from public.stocktake_expected e
        where e.session_id = p_session and e.location = p_location
          and not exists (select 1 from public.stocktake_scans s where s.session_id = p_session and s.barcode = e.barcode and s.voided_at is null)
    ), '[]'::jsonb);
end
$fn$;

-- 결과 요약: 진행 중이면 지금 계산(미리보기), 닫힌 세션이면 저장된 결과
create or replace function public.stocktake_summary(p_session uuid)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_status text; v_kinds jsonb; v_ok int; v_scanned int; v_expected int;
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
    select count(distinct s.barcode) into v_scanned from public.stocktake_scans s where s.session_id = p_session and s.voided_at is null;
    select count(distinct s.barcode) into v_ok
      from public.stocktake_scans s join public.stocktake_expected e on e.session_id = s.session_id and e.barcode = s.barcode and e.location = s.location
     where s.session_id = p_session and s.voided_at is null;
    return jsonb_build_object('status', v_status, 'expected', v_expected, 'scanned', v_scanned, 'ok', v_ok, 'kinds', v_kinds);
end
$fn$;

-- 한 물건의 스캔 이력
create or replace function public.stocktake_item_history(p_session uuid, p_barcode text)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
begin
    perform public.stocktake_require_user();
    return coalesce((
        select jsonb_agg(jsonb_build_object('location', s.location, 'by', s.scanned_by, 'hanger', s.hanger_no, 'at', s.scanned_at, 'voided', s.voided_at is not null) order by s.scanned_at)
        from public.stocktake_scans s where s.session_id = p_session and s.barcode = upper(btrim(p_barcode))), '[]'::jsonb);
end
$fn$;

-- 7) 관리자: 결과 처리
-- 기록만 남기는 처리 (found: 찾음, lost: 분실 확정, ignored: 문제 아님). 이동·폐기는 stocktake_apply_moves 로만 된다.
create or replace function public.stocktake_resolve(p_session uuid, p_kind text, p_barcodes text[], p_resolution text, p_note text default null)
returns integer language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
    perform public.stocktake_require_admin();
    if p_resolution not in ('open', 'found', 'lost', 'ignored') then
        raise exception '이 처리는 여기서 할 수 없어요. (이동·폐기는 위치 정정으로 처리)' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.stocktake_sessions where id = p_session and status = 'closed') then
        raise exception '닫힌 재고조사의 결과만 처리할 수 있어요.' using errcode = 'P0001';
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

-- 위치 정정/폐기: 정정 이동 세션을 만든다(출발지·도착지 쌍마다 1개). 22:00 자동 승인 뒤 VM이 DB·엑셀에 반영한다.
--   location_diff: p_to 가 없으면 스캔된 위치로 옮긴다.  missing: p_to 필수(예: 폐기).
create or replace function public.stocktake_apply_moves(p_session uuid, p_kind text, p_barcodes text[], p_to text default null)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_name text; v_date date; v_sess record; v_sid uuid; v_targets jsonb; v_moved int := 0; v_skipped int := 0; v_n int; v_res text;
begin
    perform public.stocktake_require_admin();
    v_name := public.stocktake_login_name();
    if p_kind not in ('location_diff', 'missing') then
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
    v_res := case when p_to = '폐기' then 'disposed' else 'moved' end;

    -- 지금도 장부(in_stock)에 그 위치로 남아 있고 아직 처리 안 된 것만. 그 사이 바뀐 건 건너뛴다.
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
           set resolution = v_res, resolved_by = v_name, resolved_at = now(), move_session_id = v_sid
         where r.session_id = p_session and r.kind = p_kind
           and r.barcode in (
               select t.barcode from jsonb_to_recordset(v_targets) as t(barcode text, raw text, from_loc text, to_loc text, product_name text, category text, price text)
               where t.from_loc = v_sess.from_loc and t.to_loc = v_sess.to_loc);
    end loop;

    v_skipped := cardinality(p_barcodes) - v_moved;
    return jsonb_build_object('moved', v_moved, 'skipped', greatest(v_skipped, 0));
end
$fn$;

-- 8) 실행 권한: anon 차단, 로그인 직원만. 내부 도우미·계산 함수는 직접 호출 불가.
revoke all on function public.stocktake_login_name(), public.stocktake_require_admin(), public.stocktake_require_user(), public.stocktake_compute(uuid) from public, anon, authenticated;
revoke all on function
    public.stocktake_start(text[], text), public.stocktake_cancel(uuid, text), public.stocktake_close(uuid),
    public.stocktake_scan_batch(uuid, text, jsonb), public.stocktake_scan_void(uuid, uuid[]), public.stocktake_location_set(uuid, text, text, text),
    public.stocktake_ledger(uuid), public.stocktake_lookup(text[]), public.stocktake_progress(uuid), public.stocktake_unscanned(uuid, text),
    public.stocktake_summary(uuid), public.stocktake_item_history(uuid, text),
    public.stocktake_resolve(uuid, text, text[], text, text), public.stocktake_apply_moves(uuid, text, text[], text)
  from public, anon;
grant execute on function
    public.stocktake_start(text[], text), public.stocktake_cancel(uuid, text), public.stocktake_close(uuid),
    public.stocktake_scan_batch(uuid, text, jsonb), public.stocktake_scan_void(uuid, uuid[]), public.stocktake_location_set(uuid, text, text, text),
    public.stocktake_ledger(uuid), public.stocktake_lookup(text[]), public.stocktake_progress(uuid), public.stocktake_unscanned(uuid, text),
    public.stocktake_summary(uuid), public.stocktake_item_history(uuid, text),
    public.stocktake_resolve(uuid, text, text[], text, text), public.stocktake_apply_moves(uuid, text, text[], text)
  to authenticated;

commit;
