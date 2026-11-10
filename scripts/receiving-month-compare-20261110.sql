-- 신규입고 앱 메인(`receiving/index.html`)의 월 누적 비교: 이번 달 vs 지난달 vs 지지난달, 같은 입고일 수까지의 입고량
-- 적용: supabase db query --linked -f scripts/receiving-month-compare-20261110.sql
--
-- 규칙:
--   입고량 = 승인(approved·processed) 세션의 물건 수, 날짜 = session_date. 메인의 "오늘 입고"와 같은 정의.
--     (엑셀 일괄 반영분처럼 세션이 없는 물건은 세지 않는다. 2026-09 이후엔 없고 2026-08 이전엔 있다.)
--   입고일 = 그날 입고가 1건 이상 있는 날. 주말·공휴일·휴무는 입고가 없어 자동으로 빠진다(공휴일 테이블이 없음.
--     평일을 영업일로 세면 2026-10의 대체공휴일 10/5·한글날 10/9가 0건 영업일로 잡혀 10월이 5일치만 쌓인 채 비교된다).
--   k = 이번 달에서 오늘(KST)까지의 입고일 수. 세 달 모두 "그 달의 첫 k입고일"까지 누적한다(오늘 포함, 오늘은 덜 쌓였을 수 있음).
-- 반환: 최근 달부터 3행(이번 달, 지난달, 지지난달). business_days는 세 행 모두 k. cutoff_date = 그 달 k번째 입고일(k=0이면 null).
-- 읽기 전용(security invoker): 기존 입고 화면들처럼 로그인 직원의 RLS를 그대로 따른다.

create or replace function public.receiving_month_compare()
returns table (month_start date, business_days integer, cutoff_date date, total integer)
language sql stable set search_path = public as $$
with t as (
    select (now() at time zone 'Asia/Seoul')::date as today
),
m as (
    select (make_date(extract(year from t.today)::int, extract(month from t.today)::int, 1)
            - make_interval(months => g))::date as month_start
    from t, generate_series(0, 2) g
),
daily as (
    select s.session_date as d, count(i.id)::int as n
    from inventory_sessions s
    join inventory_hangers h on h.session_id = s.id
    join inventory_items i on i.hanger_id = h.id
    where s.status in ('approved', 'processed')
      and s.session_date >= (select min(month_start) from m)
      and s.session_date <= (select today from t)
    group by s.session_date
),
biz as (
    select m.month_start, daily.d, daily.n,
           row_number() over (partition by m.month_start order by daily.d) as rk
    from m
    join daily on daily.d >= m.month_start and daily.d < (m.month_start + interval '1 month')::date
),
k as (
    select coalesce(max(rk), 0)::int as k
    from biz
    where month_start = (select max(month_start) from m)
)
select m.month_start,
       k.k,
       max(b.d),
       coalesce(sum(b.n), 0)::int
from m
cross join k
left join biz b on b.month_start = m.month_start and b.rk <= k.k
group by m.month_start, k.k
order by m.month_start desc
$$;

revoke all on function public.receiving_month_compare() from public, anon;
grant execute on function public.receiving_month_compare() to authenticated, service_role;
