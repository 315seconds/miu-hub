-- 홈 "어제 매출" 카드의 성수 본점 줄에 붙이는 방문객 수 · 구매 전환율
-- 적용: supabase db query --linked -f scripts/home-store-conversion-20261104.sql
--   (store_today() = store-manual-20261029.sql, store_visitors = store-visitors-20261102.sql, store_daily_receipts = store-daily-receipts-20261104.sql 이 먼저 필요)
--
-- 구매 전환율 = 구매 건수 ÷ 방문객 총합(내/외국인 나눔 없음).
--   구매 건수 = 키오스크 영수증 기준(취소·종이봉투·결제 테스트 제외, store_daily_receipts.purchases 의 성수1+성수2).
--   현금 구매는 현금매출 시트 '손님' 표시가 쌓이면 더한다(지금은 빠져 있어 전환율이 현금 구매 비율만큼 낮게 나온다: 2026-10-22~11-03 현금 줄 29건 ≈ 1~2%p).
-- 전환율은 하루 방문객이 적어 들쭉날쭉하므로 같은 계산의 최근 7일 합계를 같이 돌려준다.
-- 매장 업무 5명만 읽던 store_visitors·store_daily_receipts 를 전 직원 홈 카드에 보이기로 했으므로(2026-11-04) security definer 로 로그인한 직원 누구에게나 돌려준다.
-- 방문객이 입력되지 않았거나 두 키오스크 중 하나의 영수증이 없는 날은 그날 값을 null 로 돌려준다(틀린 전환율을 만들지 않으려고).

create or replace function public.home_store_conversion()
returns table (sale_date date, visitors integer, purchases integer, week_visitors integer, week_purchases integer)
language sql stable security definer set search_path = public as $$
    with d as (select public.store_today() - 1 as day),
    v as (select work_date, visitors from public.store_visitors where store = '성수'),
    p as (
        select work_date, sum(purchases)::integer as purchases
        from public.store_daily_receipts
        group by work_date
        having count(*) = 2
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
           (select coalesce(sum(purchases), 0)::integer from both_days)
    where auth.uid() is not null
$$;

revoke all on function public.home_store_conversion() from public, anon;
grant execute on function public.home_store_conversion() to authenticated, service_role;
