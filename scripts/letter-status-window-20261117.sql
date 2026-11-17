-- 레터 열람 현황을 최근 12주(84일)로 제한
-- 적용: supabase db query --linked -f scripts/letter-status-window-20261117.sql
--
-- 주간 letter_read_status()는 기간 제한이 없어 주마다 계속 쌓였고, 판매 sales_letter_read_status()는
-- 건수(limit 60)로만 막혀 있어 수신자 수가 바뀌면 보이는 기간이 달라졌다. 둘 다 같은 날짜 기준으로 맞춘다.
-- 데이터는 지우지 않는다(열람 이력 read_at 유지). 반환 컬럼은 그대로라 create or replace가 기존 grant를 유지한다.
-- 기간을 바꾸려면 아래 84만 고친다(두 함수 모두).

create or replace function public.letter_read_status()
returns table (id uuid, recipient_name text, week_start date, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
    select l.id, p.name, l.week_start, l.created_at, l.read_at
    from public.weekly_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin() and l.subject_name = p.name
      and l.week_start >= current_date - 84
    order by l.week_start desc, p.name
$$;

create or replace function public.sales_letter_read_status()
returns table (id uuid, recipient_name text, period_start date, period_end date, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
    select l.id, p.name, l.period_start, l.period_end, l.created_at, l.read_at
    from public.sales_letters l
    join public.profiles p on p.id = l.recipient_id
    where public.is_letter_admin()
      and l.period_end >= current_date - 84
    order by l.period_end desc, p.name
$$;
