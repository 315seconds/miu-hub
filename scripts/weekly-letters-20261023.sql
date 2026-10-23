-- 주간 프라이싱 레터 (직원별 개인 레터)
-- 적용: supabase db query --linked -f scripts/weekly-letters-20261023.sql
--
-- recipient_id : 레터를 받아 열람하는 사용자 (profiles.id = auth.uid())
-- subject_name : 레터 통계의 주인(프라이서 이름 = inventory_hangers.submitted_by).
--                정식 발송은 recipient의 name과 같고, 미리보기 때만 다르다.
-- payload      : 레터 본문 (jsonb). 생성은 work_automation/jobs/weekly_letter.py
-- read_at      : 최초 열람 시각. null이면 홈 접속 시 팝업.

create table if not exists public.weekly_letters (
    id           uuid primary key default gen_random_uuid(),
    recipient_id uuid not null references public.profiles(id) on delete cascade,
    subject_name text not null,
    week_start   date not null,
    payload      jsonb not null,
    created_at   timestamptz not null default now(),
    read_at      timestamptz,
    unique (recipient_id, subject_name, week_start)
);

create index if not exists idx_weekly_letters_recipient
    on public.weekly_letters(recipient_id, week_start desc);

alter table public.weekly_letters enable row level security;

drop policy if exists weekly_letters_select_own on public.weekly_letters;
create policy weekly_letters_select_own on public.weekly_letters
    for select to authenticated
    using (recipient_id = auth.uid());

drop policy if exists weekly_letters_mark_read on public.weekly_letters;
create policy weekly_letters_mark_read on public.weekly_letters
    for update to authenticated
    using (recipient_id = auth.uid())
    with check (recipient_id = auth.uid());

-- 새 테이블 grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md) 준수.
-- 앱은 본인 레터 조회 + read_at 갱신만 가능. payload 변조 불가(컬럼 단위 update grant).
revoke all on public.weekly_letters from anon;
revoke all on public.weekly_letters from authenticated;
grant select on public.weekly_letters to authenticated;
grant update (read_at) on public.weekly_letters to authenticated;
grant select, insert, update, delete on public.weekly_letters to service_role;
