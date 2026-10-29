-- 사입 통계(구글시트 "사입_통합 관리시트"의 허브판): 차시·차시 원가·차시 물건·4월 이전 판매·주간 스냅샷
-- 적용: supabase db query --linked -f scripts/purchase-stats-20261029.sql   (데이터 이관은 별도 파일, 이 저장소에 없음)
--
-- 용어: 차시(batch) = 한 번 사 온 묶음. 같은 회차 안의 잡화(모자)는 별도 차시(`CR5_E`)로 두고 round_code(`CR5`)로 묶는다.
-- 원가 규칙(엑셀과 동일): 물건 원가 = 최초 프라이싱 × 차시 사입 총액 ÷ 차시 최초 프라이싱 합(제외 물건은 합에서 뺌).
--   가격을 수정해도 원가 안분은 불변(최초 프라이싱 고정). 수정되는 건 현재 프라이싱(현재가)과 판매액뿐.
-- 폐기: 입고 등록 전에 폐기된 물건 = excluded(차시에서 제외, 안분 기준에서도 뺌).
--       등록 후 폐기된 물건 = inventory_items.location = '폐기' 인 물건(purchase_items_v.disposed). 수량·프라이싱 합에서 빠지고 원가는 입고 원가에 그대로 남는다.
--       폐기를 위치 대신 상태로 정리하게 되면 purchase_items_v 의 disposed 식 한 곳만 고친다.
-- 판매: sold_items(2026-04-01~) + purchase_sales_legacy(그 이전, 엑셀 판매시트에서 이관). purchase_sale_events_v 가 합친다.
--   수량이 2 이상이면 중복결제로 보고 단가(price÷quantity) 1건으로 센다. 환불(refund_date)은 환불일에 음수 이벤트.
-- 권한: 조회는 로그인 직원 전체(직원들이 같이 골라 사 오는 거라 원가도 공유), 쓰기(차시·원가·스냅샷·제외 행)는 김민지·황태훈만(서버 강제).
--   김민지 = 428a5bfc-da1f-41c4-877e-9f6e5c787291 / 황태훈 = 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d (profiles.id 고정)

create or replace function public.is_purchase_user()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '428a5bfc-da1f-41c4-877e-9f6e5c787291'::uuid,
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid
    )
$$;

-- RPC 전용: 크론(service_role)도 허용
create or replace function public.purchase_allowed()
returns boolean
language sql stable security definer set search_path = public as $$
    select public.is_purchase_user() or coalesce(auth.role(), '') = 'service_role'
$$;

-- 조회용 RPC: 로그인한 직원 누구나(+크론)
create or replace function public.purchase_can_read()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() is not null or coalesce(auth.role(), '') = 'service_role'
$$;

-- ── 출처 설정 ───────────────────────────────────────────────
alter table public.sources
    add column if not exists code          text,
    add column if not exists is_purchase   boolean not null default false,   -- 사입 추적 대상
    add column if not exists vat_included  boolean not null default true;    -- 사입 총액에 부가세 포함(간이사업자는 false)
create unique index if not exists sources_code_key on public.sources (code) where code is not null;

-- ── 차시 ────────────────────────────────────────────────────
create table if not exists public.purchase_batches (
    id            uuid primary key default gen_random_uuid(),
    source_id     uuid not null references public.sources(id),
    code          text not null unique check (code = upper(btrim(code))),   -- CR5, CR5_E, SB2501, YGH1 …
    round_code    text not null,                                            -- 같은 회차 묶음(CR5_E → CR5)
    kind          text not null default '의류' check (kind in ('의류', '잡화')),
    received_from date,                                                     -- 세탁·검수가 며칠에 걸치면 시작~끝
    received_to   date,
    vat_included  boolean not null default true,
    status        text not null default 'open' check (status in ('open', 'closed')),
    memo          text,
    created_by    text,
    created_at    timestamptz not null default now(),
    check (received_to is null or received_from is null or received_to >= received_from)
);
create index if not exists purchase_batches_source_idx on public.purchase_batches (source_id);
-- 한 회차(round_code)에는 의류 차시와 잡화 차시가 각각 하나. 직원은 "출처 + 회차"만 고르고 의류/잡화는 물건 카테고리로 갈린다(purchase_item_kind).
create unique index if not exists purchase_batches_round_kind_key on public.purchase_batches (source_id, round_code, kind);

-- 사입 총액은 차시 테이블과 분리(쓰기 권한 경계를 단순하게 두고, 나중에 다시 가리고 싶을 때 이 테이블만 정책을 바꾸면 되게).
create table if not exists public.purchase_batch_costs (
    batch_id    uuid primary key references public.purchase_batches(id) on delete cascade,
    total_cost  numeric(14,0) not null check (total_cost >= 0),
    updated_by  text,
    updated_at  timestamptz not null default now()
);

create table if not exists public.purchase_batch_items (
    barcode         text primary key check (barcode = upper(btrim(barcode))),
    batch_id        uuid not null references public.purchase_batches(id),
    initial_price   integer not null check (initial_price >= 0),   -- 최초 프라이싱(고정)
    category        text,
    last_known_price integer,                                       -- inventory_items 에 없는 옛 물건의 마지막 현재가
    excluded        boolean not null default false,                 -- 입고 등록 전 폐기 등 차시에서 제외
    excluded_reason text,
    created_at      timestamptz not null default now()
);
create index if not exists purchase_batch_items_batch_idx on public.purchase_batch_items (batch_id);

-- 2026-04-01 이전 판매(엑셀 판매시트에서 이관). 반품은 음수 금액 행.
create table if not exists public.purchase_sales_legacy (
    id         bigint generated always as identity primary key,
    sold_date  date not null,
    barcode    text not null check (barcode = upper(btrim(barcode))),
    amount     integer not null,
    category   text
);
create index if not exists purchase_sales_legacy_barcode_idx on public.purchase_sales_legacy (barcode);

-- 사입 통계에서 뺄 판매 행. sold_items 는 바코드당 1행이라 반품이 원판매를 덮어쓰는 경우 등을 여기서 제외한다.
-- (판매 정정 체계(sale_corrections)가 생기면 흡수될 임시 장치)
create table if not exists public.purchase_sale_exclusions (
    barcode    text not null check (barcode = upper(btrim(barcode))),
    sold_date  date not null,
    reason     text not null,
    created_by text,
    created_at timestamptz not null default now(),
    primary key (barcode, sold_date)
);

-- 주간 스냅샷(월요일 9시 기준 보고). 출처별 한 행. as_of = 보고일(월요일), 집계는 그 전날(일요일)까지.
create table if not exists public.purchase_snapshots (
    as_of           date not null,
    source_code     text not null,
    cost_in         numeric not null,   -- 입고 원가 합
    sales           bigint  not null,   -- 판매총액
    sold_cost       numeric not null,   -- 판매된 것의 원가
    pricing_total   bigint  not null,   -- 현재 프라이싱 합
    unsold_pricing  bigint  not null,   -- 미판매 프라이싱 합(= 프라이싱 합 − 판매총액, 엑셀 정의 유지)
    created_at      timestamptz not null default now(),
    primary key (as_of, source_code)
);

-- 작성자 기록
create or replace function public.purchase_set_actor()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text := (select name from public.profiles where id = auth.uid());
begin
    if tg_table_name = 'purchase_batches' and tg_op = 'INSERT' then
        new.created_by := coalesce(v_name, new.created_by);
    elsif tg_table_name = 'purchase_batch_costs' then
        new.updated_by := coalesce(v_name, new.updated_by);
        new.updated_at := now();
    elsif tg_table_name = 'purchase_sale_exclusions' and tg_op = 'INSERT' then
        new.created_by := coalesce(v_name, new.created_by);
    end if;
    return new;
end $$;

drop trigger if exists purchase_batches_actor on public.purchase_batches;
create trigger purchase_batches_actor before insert on public.purchase_batches
    for each row execute function public.purchase_set_actor();
drop trigger if exists purchase_batch_costs_actor on public.purchase_batch_costs;
create trigger purchase_batch_costs_actor before insert or update on public.purchase_batch_costs
    for each row execute function public.purchase_set_actor();
drop trigger if exists purchase_sale_exclusions_actor on public.purchase_sale_exclusions;
create trigger purchase_sale_exclusions_actor before insert on public.purchase_sale_exclusions
    for each row execute function public.purchase_set_actor();

-- ── RLS ─────────────────────────────────────────────────────
alter table public.purchase_batches        enable row level security;
alter table public.purchase_batch_costs    enable row level security;
alter table public.purchase_batch_items    enable row level security;
alter table public.purchase_sales_legacy   enable row level security;
alter table public.purchase_sale_exclusions enable row level security;
alter table public.purchase_snapshots      enable row level security;

drop policy if exists purchase_batches_read  on public.purchase_batches;
drop policy if exists purchase_batches_write on public.purchase_batches;
create policy purchase_batches_read  on public.purchase_batches for select to authenticated using (true);
create policy purchase_batches_write on public.purchase_batches for all to authenticated
    using (public.is_purchase_user()) with check (public.is_purchase_user());

-- 조회는 로그인 직원 전체, 쓰기는 아래 *_all(김민지·황태훈) 정책
drop policy if exists purchase_read_costs on public.purchase_batch_costs;
create policy purchase_read_costs on public.purchase_batch_costs for select to authenticated using (true);
drop policy if exists purchase_read_items on public.purchase_batch_items;
create policy purchase_read_items on public.purchase_batch_items for select to authenticated using (true);
drop policy if exists purchase_read_legacy on public.purchase_sales_legacy;
create policy purchase_read_legacy on public.purchase_sales_legacy for select to authenticated using (true);
drop policy if exists purchase_read_exclusions on public.purchase_sale_exclusions;
create policy purchase_read_exclusions on public.purchase_sale_exclusions for select to authenticated using (true);
drop policy if exists purchase_read_snapshots on public.purchase_snapshots;
create policy purchase_read_snapshots on public.purchase_snapshots for select to authenticated using (true);

drop policy if exists purchase_batch_costs_all on public.purchase_batch_costs;
create policy purchase_batch_costs_all on public.purchase_batch_costs for all to authenticated
    using (public.is_purchase_user()) with check (public.is_purchase_user());
drop policy if exists purchase_batch_items_all on public.purchase_batch_items;
create policy purchase_batch_items_all on public.purchase_batch_items for all to authenticated
    using (public.is_purchase_user()) with check (public.is_purchase_user());
drop policy if exists purchase_sales_legacy_all on public.purchase_sales_legacy;
create policy purchase_sales_legacy_all on public.purchase_sales_legacy for all to authenticated
    using (public.is_purchase_user()) with check (public.is_purchase_user());
drop policy if exists purchase_sale_exclusions_all on public.purchase_sale_exclusions;
create policy purchase_sale_exclusions_all on public.purchase_sale_exclusions for all to authenticated
    using (public.is_purchase_user()) with check (public.is_purchase_user());
drop policy if exists purchase_snapshots_all on public.purchase_snapshots;
create policy purchase_snapshots_all on public.purchase_snapshots for all to authenticated
    using (public.is_purchase_user()) with check (public.is_purchase_user());

revoke all on public.purchase_batches, public.purchase_batch_costs, public.purchase_batch_items,
              public.purchase_sales_legacy, public.purchase_sale_exclusions, public.purchase_snapshots
    from public, anon;
grant select, insert, update, delete on public.purchase_batches, public.purchase_batch_costs, public.purchase_batch_items,
              public.purchase_sales_legacy, public.purchase_sale_exclusions, public.purchase_snapshots
    to authenticated, service_role;

-- ── 뷰 (security_invoker: 호출자의 RLS가 적용되어 직원에겐 빈 결과) ──────────
create or replace view public.purchase_items_v with (security_invoker = true) as
with inv as (
    select distinct on (upper(btrim(barcode))) upper(btrim(barcode)) as barcode, price, location, source
    from public.inventory_items
    where upper(btrim(barcode)) in (select barcode from public.purchase_batch_items)
    order by upper(btrim(barcode)), created_at desc
)
select b.barcode,
       b.batch_id,
       b.initial_price,
       coalesce(i.price, b.last_known_price, b.initial_price) as current_price,
       b.category,
       b.excluded,
       (not b.excluded and coalesce(i.location, '') = '폐기') as disposed,
       -- 물건의 출처. 한 차시에 여러 출처가 섞일 수 있다(예: 에코옥션 차시에 야후옥션 물건 10벌). 허브에 없거나 출처가 빈 옛 물건은 차시의 출처로 본다.
       coalesce(nullif(i.source, ''), s.name) as item_source
from public.purchase_batch_items b
join public.purchase_batches pb on pb.id = b.batch_id
join public.sources s on s.id = pb.source_id
left join inv i on i.barcode = b.barcode;

create or replace view public.purchase_sale_events_v with (security_invoker = true) as
with u as (
    select upper(btrim(s.barcode)) as barcode,
           s.sold_date,
           s.refund_date,
           s.refund_type,
           round(s.price::numeric / greatest(abs(coalesce(nullif(s.quantity, 0), 1)), 1))::integer as unit
    from public.sold_items s
    where coalesce(s.quantity, 1) <> 0
      and upper(btrim(s.barcode)) in (select barcode from public.purchase_batch_items)
)
select u.barcode, u.sold_date as event_date, u.unit as amount, 'hub'::text as src
from u
where not exists (select 1 from public.purchase_sale_exclusions e where e.barcode = u.barcode and e.sold_date = u.sold_date)
union all
select u.barcode, u.refund_date, -u.unit, 'hub-refund'::text
from u
where u.refund_date is not null
  and coalesce(u.refund_type, '') <> '중복결제환불'
  and not exists (select 1 from public.purchase_sale_exclusions e where e.barcode = u.barcode and e.sold_date = u.sold_date)
union all
select l.barcode, l.sold_date, l.amount, 'legacy'::text
from public.purchase_sales_legacy l
where not exists (select 1 from public.purchase_sale_exclusions e where e.barcode = l.barcode and e.sold_date = l.sold_date);

grant select on public.purchase_items_v, public.purchase_sale_events_v to authenticated, service_role;

-- ── 집계 RPC ────────────────────────────────────────────────
-- 차시별 현황(p_as_of 시점). 입고일이 p_as_of 이후인 차시는 제외.
create or replace function public.purchase_batch_stats(p_as_of date default (now() at time zone 'Asia/Seoul')::date)
returns table (
    batch_id           uuid,
    code               text,
    round_code         text,
    kind               text,
    source_code        text,
    source_name        text,
    vat_included       boolean,
    status             text,
    received_from      date,
    received_to        date,
    total_cost         numeric,   -- 사입 총액(없으면 null)
    qty_total          integer,   -- 제외 물건을 뺀 입고수량(폐기 포함)
    qty_disposed       integer,
    qty_active         integer,   -- 폐기 제외 입고수량 = 판매비율 분모
    sold_qty           integer,
    sales_amount       bigint,
    sold_cost          numeric,   -- 판매된 것의 원가
    pricing_initial    bigint,    -- 최초 프라이싱 합
    pricing_current    bigint,    -- 현재 프라이싱 합(폐기 제외)
    pricing_current_all bigint    -- 현재 프라이싱 합(폐기 포함, 엑셀 대조용)
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
    if not public.purchase_can_read() then
        raise exception 'forbidden' using errcode = '42501';
    end if;

    return query
    with b as (
        select pb.id, pb.code, pb.round_code, pb.kind, s.code as source_code, s.name as source_name,
               pb.vat_included, pb.status, pb.received_from, pb.received_to, c.total_cost
        from purchase_batches pb
        join sources s on s.id = pb.source_id
        left join purchase_batch_costs c on c.batch_id = pb.id
        where pb.received_from is null or pb.received_from <= p_as_of
    ),
    net as (
        select e.barcode, sum(e.amount) as amt
        from purchase_sale_events_v e
        where e.event_date <= p_as_of
        group by e.barcode
    ),
    it as (
        select i.batch_id, i.initial_price, i.current_price, i.disposed,
               coalesce(n.amt, 0) as amt, coalesce(n.amt, 0) > 0 as sold
        from purchase_items_v i
        left join net n on n.barcode = i.barcode
        where not i.excluded and i.batch_id in (select b.id from b)
    ),
    agg as (
        select it.batch_id,
               count(*)::int                                          as qty_total,
               (count(*) filter (where it.disposed))::int             as qty_disposed,
               (count(*) filter (where it.sold))::int                 as sold_qty,
               coalesce(sum(it.amt), 0)::bigint                       as sales_amount,
               sum(it.initial_price)::bigint                          as pricing_initial,
               coalesce(sum(it.initial_price) filter (where it.sold), 0)::bigint as sold_initial,
               coalesce(sum(it.current_price) filter (where not it.disposed), 0)::bigint as pricing_current,
               coalesce(sum(it.current_price), 0)::bigint             as pricing_current_all
        from it group by it.batch_id
    )
    select b.id, b.code, b.round_code, b.kind, b.source_code, b.source_name, b.vat_included, b.status,
           b.received_from, b.received_to, b.total_cost,
           coalesce(a.qty_total, 0), coalesce(a.qty_disposed, 0),
           coalesce(a.qty_total, 0) - coalesce(a.qty_disposed, 0),
           coalesce(a.sold_qty, 0), coalesce(a.sales_amount, 0),
           case when b.total_cost is null or coalesce(a.pricing_initial, 0) = 0 then null
                else b.total_cost * a.sold_initial / a.pricing_initial end,
           coalesce(a.pricing_initial, 0), coalesce(a.pricing_current, 0), coalesce(a.pricing_current_all, 0)
    from b left join agg a on a.batch_id = b.id
    order by b.source_code, b.received_from nulls last, b.code;
end $$;

-- 차시별 카테고리 입고·판매 수량. 카테고리는 norm_category 로 통일(PK=PK셔츠, 대소문자).
create or replace function public.purchase_category_stats(p_batch_ids uuid[], p_as_of date default (now() at time zone 'Asia/Seoul')::date)
returns table (
    batch_id      uuid,
    category      text,
    qty_in        integer,    -- 폐기 제외 입고수량
    qty_disposed  integer,
    sold_qty      integer,
    sales_amount  bigint
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
    if not public.purchase_can_read() then
        raise exception 'forbidden' using errcode = '42501';
    end if;

    return query
    with net as (
        select e.barcode, sum(e.amount) as amt
        from purchase_sale_events_v e
        where e.event_date <= p_as_of
        group by e.barcode
    )
    select i.batch_id,
           public.norm_category(coalesce(nullif(i.category, ''), '(미분류)')),
           (count(*) filter (where not i.disposed))::int,
           (count(*) filter (where i.disposed))::int,
           (count(*) filter (where coalesce(n.amt, 0) > 0))::int,
           coalesce(sum(n.amt), 0)::bigint
    from purchase_items_v i
    left join net n on n.barcode = i.barcode
    where not i.excluded and i.batch_id = any(p_batch_ids)
    group by 1, 2
    order by 1, 3 desc, 2;
end $$;

-- 차시 안의 출처 구성. 에코옥션·야후옥션처럼 한 차시로 합쳐 들어온 경우 물건의 출처(inventory_items.source)별 수량·판매를 보여준다.
--   사입 총액은 합쳐서 지급한 금액이라 출처별 원가는 최초 프라이싱 비율로 안분한 추정치(차시 안 물건 원가 안분과 같은 규칙).
create or replace function public.purchase_source_mix(p_batch_ids uuid[], p_as_of date default (now() at time zone 'Asia/Seoul')::date)
returns table (
    batch_id        uuid,
    item_source     text,
    qty_in          integer,    -- 폐기 제외 입고수량
    qty_disposed    integer,
    sold_qty        integer,
    sales_amount    bigint,
    pricing_initial bigint,
    alloc_cost      numeric     -- 출처별 안분 원가(추정). 사입 총액이 없으면 null
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
    if not public.purchase_can_read() then
        raise exception 'forbidden' using errcode = '42501';
    end if;

    return query
    with net as (
        select e.barcode, sum(e.amount) as amt
        from purchase_sale_events_v e
        where e.event_date <= p_as_of
        group by e.barcode
    ),
    it as (
        select i.batch_id, i.item_source, i.initial_price, i.disposed, coalesce(n.amt, 0) as amt
        from purchase_items_v i
        left join net n on n.barcode = i.barcode
        where not i.excluded and i.batch_id = any(p_batch_ids)
    ),
    tot as (
        select it.batch_id, sum(it.initial_price) as p from it group by it.batch_id
    )
    select it.batch_id, it.item_source,
           (count(*) filter (where not it.disposed))::int,
           (count(*) filter (where it.disposed))::int,
           (count(*) filter (where it.amt > 0))::int,
           coalesce(sum(it.amt), 0)::bigint,
           sum(it.initial_price)::bigint,
           case when c.total_cost is null or t.p = 0 then null else sum(it.initial_price) * c.total_cost / t.p end
    from it
    join tot t on t.batch_id = it.batch_id
    left join purchase_batch_costs c on c.batch_id = it.batch_id
    group by it.batch_id, it.item_source, c.total_cost, t.p
    order by it.batch_id, 3 desc, it.item_source;
end $$;

-- 차시별 원가 회수 100% 초과일(누적 판매액이 처음으로 사입 총액을 넘은 날)과 입고일(시작일)부터의 일수
create or replace function public.purchase_batch_recovery()
returns table (
    batch_id      uuid,
    recovered_on  date,
    days_to_recover integer
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
    if not public.purchase_can_read() then
        raise exception 'forbidden' using errcode = '42501';
    end if;

    return query
    with daily as (
        select i.batch_id, e.event_date, sum(e.amount) as amt
        from purchase_sale_events_v e
        join purchase_items_v i on i.barcode = e.barcode
        where not i.excluded
        group by i.batch_id, e.event_date
    ),
    cum as (
        select d.batch_id, d.event_date,
               sum(d.amt) over (partition by d.batch_id order by d.event_date) as c
        from daily d
    )
    select pb.id,
           min(cum.event_date) filter (where cum.c > c.total_cost),
           (min(cum.event_date) filter (where cum.c > c.total_cost) - pb.received_from)::int
    from purchase_batches pb
    join purchase_batch_costs c on c.batch_id = pb.id
    left join cum on cum.batch_id = pb.id
    group by pb.id, pb.received_from, c.total_cost;
end $$;

-- 데이터 점검: 원가 미입력 차시 / 차시 미배정 사입 물건 / 재고에 없는 바코드의 판매(오입력 의심)
--   미배정 = 사입 출처인데 아직 어느 차시에도 없는 물건(그 출처의 가장 이른 차시 입고일 이후에 등록된 것만. 이전 차시는 추적 대상이 아님).
--   판매 행 중 inventory_items 에 없는 바코드는 2026-05-01 이후, 사입 접두어(SB·YH·CR…)로 시작하는 것만 본다(A·U 접두어는 출처를 알 수 없어 제외, 그 이전은 허브 재고 이관 전).
create or replace function public.purchase_data_checks()
returns table (kind text, barcode text, detail text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
    if not public.purchase_can_read() then
        raise exception 'forbidden' using errcode = '42501';
    end if;

    return query
    select 'no_cost'::text, null::text, pb.code
    from purchase_batches pb
    where not exists (select 1 from purchase_batch_costs c where c.batch_id = pb.id)
    union all
    (select 'unassigned'::text, upper(btrim(i.barcode)),
            i.source || ' · ' || coalesce(i.category, '') || ' · ' || coalesce(i.price::text, '') || '원 · ' || (i.created_at at time zone 'Asia/Seoul')::date
     from inventory_items i
     join sources s on s.name = i.source and s.is_purchase
     where not exists (select 1 from purchase_batch_items b where b.barcode = upper(btrim(i.barcode)))
       and (i.created_at at time zone 'Asia/Seoul')::date >=
           (select min(pb.received_from) from purchase_batches pb where pb.source_id = s.id)
     order by i.created_at desc
     limit 300)
    union all
    (select 'orphan_sale'::text, upper(btrim(x.barcode)),
            x.sold_date || ' · ' || replace(x.store, '공동판매', '') || ' · ' || x.price || '원'
     from sold_items x
     where x.sold_date >= date '2026-05-01'
       and not exists (select 1 from inventory_items i where upper(btrim(i.barcode)) = upper(btrim(x.barcode)))
       and upper(btrim(x.barcode)) ~ ('^(' || (select string_agg(code, '|') from sources where is_purchase and code is not null) || ')[0-9]')
     order by x.sold_date desc
     limit 300);
end $$;

-- 주간 스냅샷 저장(크론/수동). 보고일(p_report_date) 라벨로 저장하고 집계는 그 전날까지의 판매로 한다.
--   엑셀 보고양식과 같은 규칙: 월요일 오전 9시 기준 보고 = 일요일까지의 판매(월요일 판매는 새벽 동기화 전이라 없음).
--   출처 코드별 합계를 purchase_snapshots 에 upsert. 폐기 제외 프라이싱 합 기준.
create or replace function public.purchase_take_snapshot(p_report_date date default (now() at time zone 'Asia/Seoul')::date)
returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
    if not public.purchase_allowed() then
        raise exception 'forbidden' using errcode = '42501';
    end if;

    insert into purchase_snapshots (as_of, source_code, cost_in, sales, sold_cost, pricing_total, unsold_pricing)
    select p_report_date, st.source_code,
           coalesce(sum(st.total_cost), 0),
           coalesce(sum(st.sales_amount), 0),
           coalesce(sum(st.sold_cost), 0),
           coalesce(sum(st.pricing_current), 0),
           coalesce(sum(st.pricing_current), 0) - coalesce(sum(st.sales_amount), 0)
    from public.purchase_batch_stats(p_report_date - 1) st
    group by st.source_code
    on conflict (as_of, source_code) do update
        set cost_in = excluded.cost_in, sales = excluded.sales, sold_cost = excluded.sold_cost,
            pricing_total = excluded.pricing_total, unsold_pricing = excluded.unsold_pricing,
            created_at = now();
    get diagnostics v_n = row_count;
    return v_n;
end $$;

revoke execute on function public.is_purchase_user(), public.purchase_allowed(), public.purchase_can_read(),
    public.purchase_batch_stats(date), public.purchase_category_stats(uuid[], date), public.purchase_source_mix(uuid[], date),
    public.purchase_batch_recovery(), public.purchase_take_snapshot(date), public.purchase_data_checks()
    from public, anon;
grant execute on function public.is_purchase_user(), public.purchase_allowed(), public.purchase_can_read(),
    public.purchase_batch_stats(date), public.purchase_category_stats(uuid[], date), public.purchase_source_mix(uuid[], date),
    public.purchase_batch_recovery(), public.purchase_take_snapshot(date), public.purchase_data_checks()
    to authenticated, service_role;

-- ── 출처 시드 ────────────────────────────────────────────────
-- 사입 추적 대상 8곳. 반문화(TT)·윤관호(YGH)는 간이사업자라 사입 총액에 부가세가 없다.
insert into public.sources (name, is_active)
select '포천', true
where not exists (select 1 from public.sources where name = '포천');

update public.sources s set code = v.code, is_purchase = true, vat_included = v.vat
from (values
    ('에코옥션', 'SB',  true),
    ('야후옥션', 'YH',  true),
    ('유어스업', 'CR',  true),
    ('반문화',   'TT',  false),
    ('리클',     'RC',  true),
    ('에이치케이','HK', true),
    ('포천',     'PC',  true),
    ('윤관호',   'YGH', false)
) as v(name, code, vat)
where s.name = v.name;
