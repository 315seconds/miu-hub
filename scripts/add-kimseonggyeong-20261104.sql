-- 김성경 신규 직원 설정 + 이강철과 같은 범위의 권한 추가
-- 적용: supabase db query --linked -f scripts/add-kimseonggyeong-20261104.sql
--
-- 프로필: 이름 "김성경", role=admin (통합 관리 접근). 가입은 Supabase 대시보드에서 먼저 등록해 profiles 행이 있어야 한다.
-- 함수 3개(레터 열람 현황·매장 매니저 06·매장 업무 관리자)에 id 추가. create or replace는 기존 grant를 유지한다.
--   김성경 = 3f048532-abac-4163-92de-c1bbe858952a (profiles.id 고정)

update public.profiles set name = '김성경', role = 'admin'
where id = '3f048532-abac-4163-92de-c1bbe858952a';

create or replace function public.is_letter_admin()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        'd2f87cee-16e9-4811-bfa4-3a3c67aa48bb'::uuid,
        '3f048532-abac-4163-92de-c1bbe858952a'::uuid
    )
$$;

create or replace function public.is_logistics_user()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        '428a5bfc-da1f-41c4-877e-9f6e5c787291'::uuid,
        'd2f87cee-16e9-4811-bfa4-3a3c67aa48bb'::uuid,
        '3f048532-abac-4163-92de-c1bbe858952a'::uuid
    )
$$;

create or replace function public.is_store_manager()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        'd2f87cee-16e9-4811-bfa4-3a3c67aa48bb'::uuid,
        '3f048532-abac-4163-92de-c1bbe858952a'::uuid
    )
$$;
