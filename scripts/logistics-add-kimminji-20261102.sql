-- 매장 매니저 전용 메뉴(카테고리 판매 분석)에 김민지 추가
-- is_logistics_user()가 category_performance RPC와 store_hangers RLS를 막으므로 이 함수만 고친다.
--   최영훈 = e3781795-f971-4227-9ef3-2cc6d31b358c / 황태훈 = 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d / 김민지 = 428a5bfc-da1f-41c4-877e-9f6e5c787291

create or replace function public.is_logistics_user()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        '428a5bfc-da1f-41c4-877e-9f6e5c787291'::uuid
    )
$$;
