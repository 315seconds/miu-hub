-- 판매 레터 (평일 아침, 지난 영업일에 팔린 대상 물건 정리)
-- 적용: supabase db query --linked -f scripts/sales-letters-20261028.sql
--
-- recipient_id : 레터를 받아 열람하는 사용자 (profiles.id = auth.uid())
-- period_start/period_end : 판매일 범위(월요일 발송분은 지난주 월~일, 화~금은 전날 하루)
-- payload      : 레터 본문 (jsonb). 생성은 work_automation/jobs/daily_sales_letter.py
-- read_at      : 최초 열람 시각.
-- 수신자는 코드(work_automation)에 고정. 열람 권한은 본인 행 조회뿐이라 별도 관리자 함수는 없다.

create table if not exists public.sales_letters (
    id           uuid primary key default gen_random_uuid(),
    recipient_id uuid not null references public.profiles(id) on delete cascade,
    period_start date not null,
    period_end   date not null,
    payload      jsonb not null,
    created_at   timestamptz not null default now(),
    read_at      timestamptz,
    unique (recipient_id, period_start, period_end)
);

create index if not exists idx_sales_letters_recipient
    on public.sales_letters(recipient_id, period_end desc);

alter table public.sales_letters enable row level security;

drop policy if exists sales_letters_select_own on public.sales_letters;
create policy sales_letters_select_own on public.sales_letters
    for select to authenticated
    using (recipient_id = auth.uid());

drop policy if exists sales_letters_mark_read on public.sales_letters;
create policy sales_letters_mark_read on public.sales_letters
    for update to authenticated
    using (recipient_id = auth.uid())
    with check (recipient_id = auth.uid());

-- 새 테이블 grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md) 준수.
-- 앱은 본인 레터 조회 + read_at 갱신만 가능. payload 변조 불가(컬럼 단위 update grant).
revoke all on public.sales_letters from anon;
revoke all on public.sales_letters from authenticated;
grant select on public.sales_letters to authenticated;
grant update (read_at) on public.sales_letters to authenticated;
grant select, insert, update, delete on public.sales_letters to service_role;
