-- 홈 화면 "어제 매출" 카드용 집계 (지난 영업일 = 서버 KST 어제)
-- 적용: supabase db query --linked -f scripts/home-sales-summary-20261103.sql   (store_today() = store-manual-20261029.sql 이 먼저 적용돼 있어야 함)
--
-- 정의(sold-report 와 같은 규칙): sold_items 에서 가격>0, 종이봉투(PB…) 제외, 환불된 행(refund_date) 제외.
--   sold_items 는 공동판매 파일 '전매장매출' 시트에서 오고, 그 시트에는 키오스크 카드분과 현금·계좌분이 함께 들어 있다
--   (2026-11-03 성수 현금매출 시트 34건 중 종이봉투·당일분 7건을 뺀 27건이 같은 금액으로 sold_items 에 있음을 확인).
--   매출 리포트(sales_reports.total_sales = 카드 + 현금)와는 2026-03~10월 성수 기준 8월을 빼고 0.13% 이내로 맞는다.
--   (8월 리포트만 카드가 6,559,100원 적다 — 키오스크 원본·시트·sold_items 는 서로 일치하므로 8월 리포트 쪽 문제)
-- 비교 기준 = 7일 전 같은 요일. 매장 이름은 '공동판매' 접두사를 뗀다.
-- 최근 3일(어제 포함) 안에 판매가 한 건도 없는 매장은 뺀다(철수한 팝업이 "-100%"로 보이지 않게). 3일 연속 판매가 없는 운영 중 매장도 같이 빠진다.
-- 로그인한 직원 누구나 호출 가능(sold_items 읽기 권한과 같음). 호출자 권한(RLS)으로 실행한다. 방문객 수는 포함하지 않는다.

create or replace function public.home_sales_summary()
returns table (sale_date date, store text, sales bigint, items integer, prev_sales bigint, prev_items integer)
language sql stable set search_path = public as $$
    with d as (select public.store_today() - 1 as day)
    select (select day from d),
           btrim(replace(s.store, '공동판매', '')),
           coalesce(sum(s.price) filter (where s.sold_date = (select day from d)), 0)::bigint,
           (count(*) filter (where s.sold_date = (select day from d)))::integer,
           coalesce(sum(s.price) filter (where s.sold_date = (select day from d) - 7), 0)::bigint,
           (count(*) filter (where s.sold_date = (select day from d) - 7))::integer
    from public.sold_items s
    where auth.uid() is not null
      and s.sold_date between (select day from d) - 7 and (select day from d)
      and s.price > 0
      and s.refund_date is null
      and upper(s.barcode) not like 'PB%'
    group by btrim(replace(s.store, '공동판매', ''))
    having bool_or(s.sold_date >= (select day from d) - 2)
    order by 3 desc, 2
$$;

revoke all on function public.home_sales_summary() from public, anon;
grant execute on function public.home_sales_summary() to authenticated, service_role;
