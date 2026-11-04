-- 매장 매니저(06)·매장 업무(07) 대상에 이강철 추가
-- 적용: supabase db query --linked -f scripts/store-menus-add-kangcheol-20261104.sql
--
-- is_logistics_user() : category_performance RPC + store_hangers RLS (최영훈·황태훈·김민지 + 이강철)
-- is_store_manager()  : 매장 업무 관리자(날짜별 현황·편집·메모 확인·방문자 정정) (황태훈·최영훈 + 이강철)
-- create or replace는 기존 grant를 유지한다.
--   이강철 = d2f87cee-16e9-4811-bfa4-3a3c67aa48bb (profiles.id 고정)

create or replace function public.is_logistics_user()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        '428a5bfc-da1f-41c4-877e-9f6e5c787291'::uuid,
        'd2f87cee-16e9-4811-bfa4-3a3c67aa48bb'::uuid
    )
$$;

create or replace function public.is_store_manager()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        'd2f87cee-16e9-4811-bfa4-3a3c67aa48bb'::uuid
    )
$$;
