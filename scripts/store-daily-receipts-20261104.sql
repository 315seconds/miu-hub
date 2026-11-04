-- 성수 본점 일별 영수증 집계 (구매 전환율의 분자). VM 작업 kiwoom_receipts_daily.py 가 service_role 로 upsert 한다.
-- 적용: supabase db query --linked -f scripts/store-daily-receipts-20261104.sql   (store-manual-20261029.sql 이 먼저 적용돼 있어야 함)
--
-- 한 행 = 날짜 × 키오스크(성수1·성수2). 키오스크마다 같은 날 다시 쓰면 덮어쓴다(최근 7일을 매일 다시 받아 계산).
--   purchases = 구매 건수(결제 합이 양수인 전표 − 종이봉투 전용 − 결제 테스트 − 취소된 판매). 현금은 키오스크 전표가 없어 여기에 없다.
--   card_net·qr_net·other_net = 결제수단별 순매출(취소 반영). other = 행사할인·임의할인 등.
-- 읽기는 매장 업무 5명(store_manual_can_use), 쓰기는 service_role 뿐(화면에서 쓰지 않음).

create table if not exists public.store_daily_receipts (
    work_date         date    not null,
    kiosk             text    not null check (kiosk in ('성수1', '성수2')),
    slips             integer not null check (slips >= 0),
    purchases         integer not null check (purchases >= 0),
    bag_only          integer not null default 0,
    test              integer not null default 0,
    canceled_sales    integer not null default 0,
    cancel_slips      integer not null default 0,
    partial_refunds   integer not null default 0,
    unmatched_cancels integer not null default 0,
    card_net          bigint  not null default 0,
    qr_net            bigint  not null default 0,
    other_net         bigint  not null default 0,
    updated_at        timestamptz not null default now(),
    primary key (work_date, kiosk)
);

create or replace function public.store_daily_receipts_touch() returns trigger
language plpgsql as $$
begin
    new.updated_at := now();
    return new;
end
$$;
drop trigger if exists store_daily_receipts_touch on public.store_daily_receipts;
create trigger store_daily_receipts_touch before update on public.store_daily_receipts
    for each row execute function public.store_daily_receipts_touch();

alter table public.store_daily_receipts enable row level security;
drop policy if exists store_daily_receipts_select on public.store_daily_receipts;
create policy store_daily_receipts_select on public.store_daily_receipts
    for select to authenticated using (public.store_manual_can_use());

-- 새 테이블 grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md) 준수
revoke all on public.store_daily_receipts from anon, authenticated;
grant select on public.store_daily_receipts to authenticated;
grant select, insert, update, delete on public.store_daily_receipts to service_role;
revoke all on function public.store_daily_receipts_touch() from public, anon, authenticated;
