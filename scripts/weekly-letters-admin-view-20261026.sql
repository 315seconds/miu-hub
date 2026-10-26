-- 주간 레터 열람 현황에서 "실제 발송된 레터 보기" (황태훈 전용)
-- 적용: supabase db query --linked -f scripts/weekly-letters-admin-view-20261026.sql
--
-- 1) letter_read_status()가 레터 id도 돌려주도록 반환 컬럼을 늘린다(반환형 변경이라 drop 후 재생성).
-- 2) letter_admin_view(p_id)가 정식 발송분 1건의 본문(payload)을 돌려준다.
--    weekly_letters RLS는 "본인 레터만 조회"라 그대로 두고, is_letter_admin()(황태훈 1명)만 SECURITY DEFINER로 연다.
--    미리보기(통계 주인 != 수신자)는 열람 현황 대상이 아니므로 여기서도 제외한다.
--    읽기 전용: read_at은 건드리지 않는다(관리자가 봐도 수신자의 열람 기록이 바뀌지 않음).

drop function if exists public.letter_read_status();

create function public.letter_read_status()
returns table (id uuid, recipient_name text, week_start date, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
    select l.id, p.name, l.week_start, l.created_at, l.read_at
    from public.weekly_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin() and l.subject_name = p.name
    order by l.week_start desc, p.name
$$;

create or replace function public.letter_admin_view(p_id uuid)
returns table (id uuid, subject_name text, week_start date, read_at timestamptz, payload jsonb)
language sql stable security definer set search_path = public as $$
    select l.id, l.subject_name, l.week_start, l.read_at, l.payload
    from public.weekly_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin() and l.id = p_id and l.subject_name = p.name
$$;

revoke all on function public.letter_read_status() from public, anon;
revoke all on function public.letter_admin_view(uuid) from public, anon;
grant execute on function public.letter_read_status() to authenticated, service_role;
grant execute on function public.letter_admin_view(uuid) to authenticated, service_role;
