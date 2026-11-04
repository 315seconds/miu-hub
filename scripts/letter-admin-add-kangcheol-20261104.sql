-- 레터 열람 현황 대상에 이강철 추가 (황태훈 + 이강철)
-- 적용: supabase db query --linked -f scripts/letter-admin-add-kangcheol-20261104.sql
--
-- is_letter_admin()이 letter_read_status / letter_admin_view / sales_letter_read_status / sales_letter_admin_view의
-- 게이트이므로 이 함수만 고치면 주간·판매 레터 열람 현황과 발송 내용 보기가 모두 열린다.
-- create or replace는 기존 grant를 유지한다.
--   황태훈 = 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d / 이강철 = d2f87cee-16e9-4811-bfa4-3a3c67aa48bb (profiles.id 고정)

create or replace function public.is_letter_admin()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        'd2f87cee-16e9-4811-bfa4-3a3c67aa48bb'::uuid
    )
$$;
