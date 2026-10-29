-- 판매 레터 열람 현황 + 발송된 레터 보기 (황태훈 전용)
-- 적용: supabase db query --linked -f scripts/sales-letters-admin-20261029.sql
--
-- sales_letters의 RLS는 "본인 레터만 조회"라서 관리자도 남의 열람 여부·내용을 못 본다.
-- 주간 레터와 같은 방식으로, is_letter_admin()(황태훈 1명)만 SECURITY DEFINER 함수로 연다.
-- 읽기 전용: read_at은 건드리지 않는다(관리자가 봐도 수신자의 열람 기록이 바뀌지 않음).
-- 열람 현황 = 최근 60통(수신자 1명 기준 약 3개월).

create or replace function public.sales_letter_read_status()
returns table (id uuid, recipient_name text, period_start date, period_end date, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
    select l.id, p.name, l.period_start, l.period_end, l.created_at, l.read_at
    from public.sales_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin()
    order by l.period_end desc, p.name
    limit 60
$$;

create or replace function public.sales_letter_admin_view(p_id uuid)
returns table (id uuid, recipient_name text, period_start date, period_end date, read_at timestamptz, payload jsonb)
language sql stable security definer set search_path = public as $$
    select l.id, p.name, l.period_start, l.period_end, l.read_at, l.payload
    from public.sales_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin() and l.id = p_id
$$;

revoke all on function public.sales_letter_read_status() from public, anon;
revoke all on function public.sales_letter_admin_view(uuid) from public, anon;
grant execute on function public.sales_letter_read_status() to authenticated, service_role;
grant execute on function public.sales_letter_admin_view(uuid) to authenticated, service_role;
