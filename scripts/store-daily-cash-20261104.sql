-- 성수 본점 일별 현금 구매(손님) 집계. VM 작업 cash_customers_daily.py 가 현금매출 시트의 H열 '손님'(✓)·I열 '국적'(내국/외국)을 읽어 service_role 로 upsert 한다.
-- 적용: supabase db query --linked -f scripts/store-daily-cash-20261104.sql   (store-manual-20261029.sql 이 먼저 필요)
--
-- 한 행 = 날짜. 추적 시작일(2026-11-04) 이후 모든 날짜에 행이 있다(현금이 없던 날은 0). 행이 없는 날 = 아직 손님 표시를 하지 않던 날.
--   purchases_* = 현금 구매 건수(손님 수), net_* = 그 손님들의 현금 매출. domestic = 내국, foreign = 외국, unknown = 국적 미표시.
--   orphan_rows = 손님 ✓ 없이 입력된 줄(누락), refund_rows = 음수(환불) 줄, checked_without_items = ✓만 있고 상품 없는 줄.
-- 읽기는 매장 업무 5명(store_manual_can_use), 쓰기는 service_role 뿐.

create table if not exists public.store_daily_cash (
    work_date             date    primary key,
    purchases_domestic    integer not null default 0 check (purchases_domestic >= 0),
    purchases_foreign     integer not null default 0 check (purchases_foreign >= 0),
    purchases_unknown     integer not null default 0 check (purchases_unknown >= 0),
    net_domestic          bigint  not null default 0,
    net_foreign           bigint  not null default 0,
    net_unknown           bigint  not null default 0,
    orphan_rows           integer not null default 0,
    refund_rows           integer not null default 0,
    checked_without_items integer not null default 0,
    updated_at            timestamptz not null default now()
);

create or replace function public.store_daily_cash_touch() returns trigger
language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end
$$;
drop trigger if exists store_daily_cash_touch on public.store_daily_cash;
create trigger store_daily_cash_touch before update on public.store_daily_cash
    for each row execute function public.store_daily_cash_touch();

alter table public.store_daily_cash enable row level security;
drop policy if exists store_daily_cash_select on public.store_daily_cash;
create policy store_daily_cash_select on public.store_daily_cash
    for select to authenticated using (public.store_manual_can_use());

-- 새 테이블 grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md) 준수
revoke all on public.store_daily_cash from anon, authenticated;
grant select on public.store_daily_cash to authenticated;
grant select, insert, update, delete on public.store_daily_cash to service_role;
revoke all on function public.store_daily_cash_touch() from public, anon, authenticated;
