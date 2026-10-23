-- 주간 레터 열람 현황 (황태훈 전용)
-- 적용: supabase db query --linked -f scripts/weekly-letters-admin-20261023.sql
--
-- weekly_letters의 RLS는 "본인 레터만 조회"라서 관리자도 남의 열람 여부를 못 본다.
-- 레터 본문(payload)은 노출하지 않고 열람 여부만 돌려주는 SECURITY DEFINER 함수로 연다.
-- 대상: 황태훈 1명. 관리자(role=admin) 전체가 아님 — 강현성·김민우도 admin이면서 레터 수신자라서
--       다른 직원의 열람 여부를 서로 보게 되는 걸 막기 위함. 대상을 넓히려면 is_letter_admin()만 고친다.
-- 황태훈 = profiles.id 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d (이름은 바뀔 수 있어 id로 고정)

create or replace function public.is_letter_admin()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() = '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid
$$;

-- 정식 발송분(통계 주인 = 수신자)만. 열람 시각과 도착 시각만 반환.
create or replace function public.letter_read_status()
returns table (recipient_name text, week_start date, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
    select p.name, l.week_start, l.created_at, l.read_at
    from public.weekly_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin() and l.subject_name = p.name
    order by l.week_start desc, p.name
$$;

revoke all on function public.is_letter_admin() from public, anon;
revoke all on function public.letter_read_status() from public, anon;
grant execute on function public.is_letter_admin() to authenticated, service_role;
grant execute on function public.letter_read_status() to authenticated, service_role;
