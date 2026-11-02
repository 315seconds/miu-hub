-- 성수 본점 일별 방문자 수 (매장 업무 화면 `manual/`에 입력칸)
-- 적용: supabase db query --linked -f scripts/store-visitors-20261102.sql   (store-manual-20261029.sql 이 먼저 적용돼 있어야 함)
--
-- 권한(서버 강제, 기존 매장 업무와 같은 5명):
--   직원·관리자 = 읽기 + 오늘 값 입력/수정 (store_visitors_set)
--   관리자      = 위 + 지난 날짜 입력/정정 (store_visitors_set_day, 오늘 이전만)
-- 규칙:
--   성수 본점만 받는다(키오스크 매장은 무인이라 센 사람이 없음). 테이블은 매장 컬럼이 있어 나중에 넓히기 쉽지만 RPC 가 '성수' 밖은 거절한다.
--   (날짜, 매장)당 하루 총합 한 값. 같은 날 다시 저장하면 덮어쓴다(마지막 저장자·시각이 남음). 날짜는 서버 KST 오늘만.
--   과거 슬랙 기록 이관은 이 파일이 아니라 일회성 SQL(데이터는 저장소에 두지 않음)로 넣는다.

create table if not exists public.store_visitors (
    work_date   date    not null,
    store       text    not null,
    visitors    integer not null check (visitors between 0 and 100000),
    updated_by  text    not null,
    updated_at  timestamptz not null default now(),
    primary key (work_date, store)
);

alter table public.store_visitors enable row level security;
drop policy if exists store_visitors_select on public.store_visitors;
create policy store_visitors_select on public.store_visitors
    for select to authenticated using (public.store_manual_can_use());

-- 새 테이블 grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md) 준수. 쓰기는 RPC 로만.
revoke all on public.store_visitors from anon, authenticated;
grant select on public.store_visitors to authenticated;
grant select, insert, update, delete on public.store_visitors to service_role;

-- 직원: 오늘(KST) 값만
create or replace function public.store_visitors_set(p_store text, p_visitors integer)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if not public.store_manual_can_use() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    if p_store is distinct from '성수' then
        raise exception '방문자 수는 성수 본점만 기록해요.' using errcode = 'P0001';
    end if;
    if p_visitors is null or p_visitors < 0 or p_visitors > 100000 then
        raise exception '방문자 수는 0 이상의 정수로 적어 주세요.' using errcode = 'P0001';
    end if;
    insert into public.store_visitors (work_date, store, visitors, updated_by, updated_at)
    values (public.store_today(), p_store, p_visitors, public.store_manual_name(), now())
    on conflict (work_date, store) do update
        set visitors = excluded.visitors, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end
$$;

-- 관리자: 지난 날짜(오늘 포함, 미래 제외) 입력·정정
create or replace function public.store_visitors_set_day(p_store text, p_date date, p_visitors integer)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if not public.is_store_manager() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    if p_store is distinct from '성수' then
        raise exception '방문자 수는 성수 본점만 기록해요.' using errcode = 'P0001';
    end if;
    if p_date is null or p_date > public.store_today() then
        raise exception '오늘 이후 날짜는 기록할 수 없어요.' using errcode = 'P0001';
    end if;
    if p_visitors is null or p_visitors < 0 or p_visitors > 100000 then
        raise exception '방문자 수는 0 이상의 정수로 적어 주세요.' using errcode = 'P0001';
    end if;
    insert into public.store_visitors (work_date, store, visitors, updated_by, updated_at)
    values (p_date, p_store, p_visitors, public.store_manual_name(), now())
    on conflict (work_date, store) do update
        set visitors = excluded.visitors, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end
$$;

revoke all on function public.store_visitors_set(text, integer), public.store_visitors_set_day(text, date, integer)
    from public, anon;
grant execute on function public.store_visitors_set(text, integer), public.store_visitors_set_day(text, date, integer)
    to authenticated, service_role;
