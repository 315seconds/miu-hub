-- 카테고리 판매 분석(최영훈·황태훈 전용): 행거수 이력 테이블 + 집계 RPC
-- 적용: supabase db query --linked -f scripts/category-performance-20261027.sql
--
-- store_hangers: 매장·카테고리별 행거수 "변경 이력". effective_date부터 다음 변경일 전날까지 그 값이 유효하다.
--   조회 기간의 일수 가중 평균 행거수 = Σ(유효 행거수 × 일수) / 기간 일수.
--   가장 오래된 입력값 이전 기간에는 그 값을 그대로 적용한다(backfilled 로 표시).
-- category_performance(): 기간·매장 선택에 대해 매장 × 카테고리별 판매·가격대·판매소요일·재고·행거수를 한 번에 돌려준다.
--   store='전체' 행은 p_stores로 고른 매장 합산(판매소요일 중앙값은 합산 데이터에서 다시 계산).
-- 대상: 최영훈, 황태훈 (profiles.id 고정; 이름은 바뀔 수 있어 id로 묶음). 넓히려면 is_logistics_user()만 고친다.
--   최영훈 = e3781795-f971-4227-9ef3-2cc6d31b358c / 황태훈 = 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d

create or replace function public.is_logistics_user()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid
    )
$$;

-- 카테고리 이름 통일: 대소문자·공백, 그리고 PK / PK셔츠를 혼용해 입력해 왔으므로 같은 것으로 본다(온PK = 온PK셔츠).
-- inventory_items 원본 값은 건드리지 않고 집계할 때만 통일한다.
create or replace function public.norm_category(c text)
returns text
language sql immutable as $$
    select case upper(btrim(c))
        when 'PK'  then 'PK셔츠'
        when '온PK' then '온PK셔츠'
        else upper(btrim(c))
    end
$$;

create table if not exists public.store_hangers (
    id             uuid primary key default gen_random_uuid(),
    store          text not null,                 -- 짧은 매장명(성수, 무성 …) = locations.name
    category       text not null,                 -- norm_category(inventory_items.category) 형태
    effective_date date not null,
    hangers        numeric(5,1) not null check (hangers >= 0),
    updated_by     text,
    updated_at     timestamptz not null default now(),
    unique (store, category, effective_date),
    check (category = upper(btrim(category)))
);

create or replace function public.store_hangers_set_actor()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    new.updated_by := coalesce((select name from public.profiles where id = auth.uid()), new.updated_by);
    new.updated_at := now();
    return new;
end $$;

drop trigger if exists store_hangers_set_actor on public.store_hangers;
create trigger store_hangers_set_actor
    before insert or update on public.store_hangers
    for each row execute function public.store_hangers_set_actor();

alter table public.store_hangers enable row level security;
drop policy if exists store_hangers_logistics on public.store_hangers;
create policy store_hangers_logistics on public.store_hangers
    for all to authenticated
    using (public.is_logistics_user()) with check (public.is_logistics_user());

revoke all on public.store_hangers from public, anon;
grant select, insert, update, delete on public.store_hangers to authenticated, service_role;

create or replace function public.category_performance(p_from date, p_to date, p_stores text[] default null)
returns table (
    store            text,
    category         text,
    sold_qty         integer,
    revenue          bigint,
    bands            integer[],      -- 개당가 <1만, 1~2, 2~3, 3~4, 4~5, 5~7, 7~10, 10만~ (수량)
    sell_days_n      integer,        -- 판매소요일 계산 가능 건수(입고일을 아는 판매)
    sold_30d         integer,        -- 그중 입고 후 30일 이내 판매
    sell_days_median numeric,
    stock_qty        integer,        -- 현재 매장 재고(기간과 무관, 지금 시점)
    avg_hangers      numeric,        -- 기간 일수 가중 평균(없으면 null)
    hanger_days      numeric,
    start_hangers    numeric,
    end_hangers      numeric,
    hanger_changes   integer,        -- 기간 중 값이 바뀐 횟수
    hanger_updated   date,           -- 기간 끝 기준 마지막 입력일
    hanger_backfilled boolean        -- 기간 시작이 첫 입력일보다 앞서 첫 값으로 채웠는가
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
    if not public.is_logistics_user() then
        raise exception 'forbidden' using errcode = '42501';
    end if;
    if p_from is null or p_to is null or p_to < p_from then
        raise exception 'invalid period' using errcode = '22023';
    end if;

    return query
    with
    st as (
        select distinct replace(s.store, '공동판매', '') as store
        from sold_items s
        where s.sold_date between p_from and p_to
          and (p_stores is null or replace(s.store, '공동판매', '') = any(p_stores))
        union
        select x from unnest(p_stores) x
    ),
    inv as (
        select distinct on (i.barcode) i.barcode, i.category, i.created_at
        from inventory_items i
        where i.barcode in (select s.barcode from sold_items s where s.sold_date between p_from and p_to)
        order by i.barcode, i.created_at
    ),
    sold as (
        select replace(s.store, '공동판매', '') as store,
               public.norm_category(coalesce(nullif(v.category, ''),
                    case when s.barcode ilike 'pb%' then '봉투' else '(카테고리 미확인)' end)) as category,
               coalesce(s.quantity, 1) as q,
               s.price,
               abs(s.price::numeric / coalesce(s.quantity, 1)) as unit,
               s.sold_date - (v.created_at at time zone 'Asia/Seoul')::date as dd
        from sold_items s
        left join inv v on v.barcode = s.barcode
        where s.sold_date between p_from and p_to
          and s.refund_date is null
          and coalesce(s.quantity, 1) <> 0
          and replace(s.store, '공동판매', '') in (select st.store from st)
    ),
    sa as (
        select sd.store, sd.category,
               sum(sd.q)::int as sold_qty,
               sum(sd.price)::bigint as revenue,
               array[
                   coalesce(sum(sd.q) filter (where sd.unit < 10000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 10000 and sd.unit < 20000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 20000 and sd.unit < 30000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 30000 and sd.unit < 40000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 40000 and sd.unit < 50000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 50000 and sd.unit < 70000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 70000 and sd.unit < 100000), 0)::int,
                   coalesce(sum(sd.q) filter (where sd.unit >= 100000), 0)::int
               ] as bands,
               (count(*) filter (where sd.q > 0 and sd.dd is not null))::int as n,
               (count(*) filter (where sd.q > 0 and sd.dd is not null and sd.dd <= 30))::int as d30,
               (percentile_cont(0.5) within group (order by sd.dd)
                    filter (where sd.q > 0 and sd.dd is not null))::numeric as med
        from sold sd
        group by grouping sets ((sd.store, sd.category), (sd.category))
    ),
    stk as (
        select i.location as store, public.norm_category(i.category) as category, count(*)::int as n
        from inventory_items i
        where i.status = 'in_stock'
          and i.category is not null and btrim(i.category) <> ''
          and i.location in (select st.store from st)
        group by 1, 2
    ),
    seg as (
        select h.store, h.category, h.hangers, h.effective_date as s,
               lead(h.effective_date) over w as nxt,
               row_number() over w as rn
        from store_hangers h
        where h.store in (select st.store from st)
        window w as (partition by h.store, h.category order by h.effective_date)
    ),
    segc as (
        select g.store, g.category, g.hangers, g.s, g.rn,
               case when g.rn = 1 then p_from else greatest(g.s, p_from) end as a,
               least(coalesce(g.nxt - 1, p_to), p_to) as b
        from seg g
    ),
    hg as (
        select c.store, c.category,
               (sum(c.hangers * (c.b - c.a + 1)) filter (where c.b >= c.a))::numeric as hd,
               (sum(c.b - c.a + 1) filter (where c.b >= c.a))::numeric as cd,
               (count(*) filter (where c.b >= c.a))::int as segs,
               (array_agg(c.hangers order by c.a) filter (where c.b >= c.a))[1] as start_h,
               (array_agg(c.hangers order by c.a desc) filter (where c.b >= c.a))[1] as end_h,
               coalesce(max(c.s) filter (where c.s <= p_to), min(c.s)) as upd,
               coalesce(bool_or(c.rn = 1 and c.s > p_from), false) as backfilled
        from segc c
        group by c.store, c.category
    ),
    keys as (
        select sa.store, sa.category from sa where sa.store is not null
        union select stk.store, stk.category from stk
        union select hg.store, hg.category from hg where hg.hd is not null
    ),
    lvl as (
        select k.store, k.category,
               coalesce(sa.sold_qty, 0) as sold_qty, coalesce(sa.revenue, 0)::bigint as revenue,
               coalesce(sa.bands, array[0,0,0,0,0,0,0,0]) as bands,
               coalesce(sa.n, 0) as n, coalesce(sa.d30, 0) as d30, sa.med,
               coalesce(stk.n, 0) as stock,
               hg.hd / nullif(hg.cd, 0) as avg_h, hg.hd, hg.start_h, hg.end_h,
               greatest(coalesce(hg.segs, 0) - 1, 0) as chg, hg.upd, coalesce(hg.backfilled, false) as backfilled
        from keys k
        left join sa  on sa.store = k.store and sa.category = k.category
        left join stk on stk.store = k.store and stk.category = k.category
        left join hg  on hg.store = k.store and hg.category = k.category
    ),
    tot as (
        select '전체'::text as store, c.category,
               coalesce(t.sold_qty, 0) as sold_qty, coalesce(t.revenue, 0)::bigint as revenue,
               coalesce(t.bands, array[0,0,0,0,0,0,0,0]) as bands,
               coalesce(t.n, 0) as n, coalesce(t.d30, 0) as d30, t.med,
               coalesce(l.stock, 0)::int as stock,
               l.avg_h, l.hd, l.start_h, l.end_h, coalesce(l.chg, 0)::int as chg, l.upd, coalesce(l.backfilled, false) as backfilled
        from (select distinct k.category from keys k) c
        left join sa t on t.store is null and t.category = c.category
        left join (
            select x.category, sum(x.stock) as stock, sum(x.avg_h) as avg_h, sum(x.hd) as hd,
                   sum(x.start_h) as start_h, sum(x.end_h) as end_h, sum(x.chg) as chg,
                   max(x.upd) as upd, bool_or(x.backfilled) as backfilled
            from lvl x group by x.category
        ) l on l.category = c.category
    )
    select r.store, r.category, r.sold_qty, r.revenue, r.bands, r.n, r.d30, round(r.med, 1),
           r.stock, round(r.avg_h, 2), round(r.hd, 1), r.start_h, r.end_h, r.chg, r.upd, r.backfilled
    from (
        select * from lvl
        union all
        select * from tot
    ) r
    order by r.store, r.revenue desc, r.category;
end $$;

revoke all on function public.is_logistics_user() from public, anon;
revoke all on function public.category_performance(date, date, text[]) from public, anon;
grant execute on function public.is_logistics_user() to authenticated, service_role;
grant execute on function public.category_performance(date, date, text[]) to authenticated, service_role;
