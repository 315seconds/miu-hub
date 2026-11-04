-- 홈 "어제 매출" 카드의 성수 본점 줄에 붙이는 방문객 수 · 구매 전환율 · 국내/해외 결제 비중
-- 적용: supabase db query --linked -f scripts/home-store-conversion-20261104.sql
--   (store_today() = store-manual-20261029.sql, store_visitors = store-visitors-20261102.sql,
--    store_daily_receipts = store-daily-receipts-20261104.sql + store-daily-receipts-split-20261104.sql,
--    store_daily_cash = store-daily-cash-20261104.sql 이 먼저 필요)
--
-- 구매 전환율 = 구매 건수 ÷ 방문객 총합(내/외국인 나눔 없음).
--   구매 건수 = 키오스크 영수증 기준(취소·종이봉투·결제 테스트 제외, store_daily_receipts.purchases 의 성수1+성수2)
--             + 그 날 현금 구매(store_daily_cash, 현금매출 시트 손님 ✓). store_daily_cash 에 행이 없는 날(2026-11-04 이전)은 키오스크만이고 cash_included=false.
-- 국내/해외 = 카드·QR 순매출을 발급사명으로 나눈 값 + 현금 매출을 국적(내국/외국)으로 나눈 값. 국적 미표시 현금은 어느 쪽에도 넣지 않는다.
--   두 키오스크 모두 값이 있는 날만 쓴다.
-- 하루 값은 들쭉날쭉하므로 같은 계산의 최근 7일 합계를 같이 돌려준다(현금 추적 이전 날짜가 섞이면 그 날들은 카드·QR만이다).
-- 매장 업무 5명만 읽던 store_visitors·store_daily_receipts·store_daily_cash 를 전 직원 홈 카드에 보이기로 했으므로(2026-11-04) security definer 로 로그인한 직원 누구에게나 돌려준다.
-- 방문객이 입력되지 않았거나 두 키오스크 중 하나의 영수증이 없는 날은 그날 값을 null 로 돌려준다(틀린 비율을 만들지 않으려고).
-- 반환 열이 바뀌어 drop 후 다시 만든다.

drop function if exists public.home_store_conversion();

create function public.home_store_conversion()
returns table (sale_date date, visitors integer, purchases integer, week_visitors integer, week_purchases integer,
               foreign_net bigint, domestic_net bigint, week_foreign_net bigint, week_domestic_net bigint, cash_included boolean)
language sql stable security definer set search_path = public as $$
    with d as (select public.store_today() - 1 as day),
    v as (select work_date, visitors from public.store_visitors where store = '성수'),
    c as (
        select work_date, purchases_domestic + purchases_foreign + purchases_unknown as purchases, net_domestic, net_foreign
        from public.store_daily_cash
    ),
    k as (
        select work_date, sum(purchases)::integer as purchases
        from public.store_daily_receipts
        group by work_date
        having count(*) = 2
    ),
    p as (
        select k.work_date, k.purchases + coalesce(c.purchases, 0) as purchases, (c.work_date is not null) as with_cash
        from k left join c using (work_date)
    ),
    s0 as (
        select work_date, sum(foreign_net)::bigint as f, sum(domestic_net)::bigint as dm
        from public.store_daily_receipts
        where foreign_net is not null and domestic_net is not null
        group by work_date
        having count(*) = 2
    ),
    s as (
        select s0.work_date, s0.f + coalesce(c.net_foreign, 0) as foreign_net, s0.dm + coalesce(c.net_domestic, 0) as domestic_net
        from s0 left join c using (work_date)
    ),
    both_days as (
        select v.work_date, v.visitors, p.purchases
        from v join p using (work_date)
        where v.work_date between (select day from d) - 6 and (select day from d)
    )
    select (select day from d),
           (select visitors from v where work_date = (select day from d)),
           (select purchases from p where work_date = (select day from d)),
           (select coalesce(sum(visitors), 0)::integer from both_days),
           (select coalesce(sum(purchases), 0)::integer from both_days),
           (select foreign_net from s where work_date = (select day from d)),
           (select domestic_net from s where work_date = (select day from d)),
           (select coalesce(sum(foreign_net), 0)::bigint from s where work_date between (select day from d) - 6 and (select day from d)),
           (select coalesce(sum(domestic_net), 0)::bigint from s where work_date between (select day from d) - 6 and (select day from d)),
           coalesce((select with_cash from p where work_date = (select day from d)), false)
    where auth.uid() is not null
$$;

revoke all on function public.home_store_conversion() from public, anon;
grant execute on function public.home_store_conversion() to authenticated, service_role;
