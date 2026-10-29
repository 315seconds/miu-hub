-- 매장 업무 체크 항목에 "적용 요일" 추가 (store-manual-20261029.sql 다음에 적용)
-- 적용: supabase db query --linked -f scripts/store-manual-weekdays-20261029.sql
--
-- weekdays: 1=월 … 7=일(Postgres isodow). null = 매일. 요일이 아닌 날에는 그 매장 체크리스트에 항목이 나오지 않고
-- 분모(total_items)에도 안 들어가서, 월·수·금에만 하는 일도 그 외 요일에 100%가 될 수 있다.
-- 이미 체크된 항목의 요일을 나중에 바꿔도 지난 기록은 그대로 남는다.

alter table public.checklist_items
    add column if not exists weekdays smallint[]
    check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[]));

-- 성수 본점의 "주 3번(월 수 금)" 두 항목(마네킹 디피, 스팀)
update public.checklist_items
set weekdays = array[1,3,5]::smallint[]
where store = '성수'
  and (content like '주 3번(월 수 금) 마네킹 디피%' or content like '입고 수량 확인 후 구겨진 옷은 스팀%');

-- 체크 표시/해제: 체크는 오늘 요일에 해당하는 항목만(해제는 요일과 무관)
create or replace function public.checklist_set(p_store text, p_item uuid, p_checked boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_today date := public.store_today();
    v_dow   smallint := extract(isodow from public.store_today())::smallint;
    v_name  text;
    v_total integer;
begin
    if not public.store_manual_can_use() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    v_name := public.store_manual_name();
    if not exists (select 1 from public.locations l where l.name = p_store and l.is_active) then
        raise exception '알 수 없는 매장이에요: %', p_store using errcode = 'P0001';
    end if;
    if p_checked and not exists (select 1 from public.checklist_items i
                   where i.id = p_item and i.is_active and (i.store is null or i.store = p_store)
                     and (i.weekdays is null or v_dow = any(i.weekdays))) then
        raise exception '이 매장·오늘 요일에 없는 체크 항목이에요.' using errcode = 'P0001';
    end if;

    if p_checked then
        insert into public.checklist_checks (work_date, store, item_id, checked_by)
        values (v_today, p_store, p_item, v_name)
        on conflict (work_date, store, item_id) do nothing;
    else
        delete from public.checklist_checks
        where work_date = v_today and store = p_store and item_id = p_item;
    end if;

    select count(*) into v_total from public.checklist_items i
    where i.is_active and (i.store is null or i.store = p_store)
      and (i.weekdays is null or v_dow = any(i.weekdays));
    insert into public.checklist_days (work_date, store, total_items)
    values (v_today, p_store, v_total)
    on conflict (work_date, store) do update set total_items = excluded.total_items;
end
$$;

-- 기간 요약: 체크 기록이 없는 날의 분모(total_items)도 그 날짜의 요일 기준으로 센다
create or replace function public.store_checklist_overview(p_from date, p_to date)
returns table (work_date date, store text, total_items integer, checked_count integer,
               last_checked_by text, last_checked_at timestamptz, note_count integer, unconfirmed_count integer)
language sql stable security definer set search_path = public as $$
    with c as (
        select k.work_date, k.store, count(*)::integer as n,
               (array_agg(k.checked_by order by k.checked_at desc))[1] as who,
               max(k.checked_at) as at
        from public.checklist_checks k
        where k.work_date between p_from and p_to
        group by k.work_date, k.store
    ), nn as (
        select s.work_date, s.store, count(*)::integer as cnt,
               (count(*) filter (where s.confirmed_at is null))::integer as unconf
        from public.store_notes s
        where s.work_date between p_from and p_to
        group by s.work_date, s.store
    ), keys as (
        select c.work_date, c.store from c
        union
        select nn.work_date, nn.store from nn
    )
    select keys.work_date, keys.store,
           coalesce(d.total_items,
                    (select count(*)::integer from public.checklist_items i
                     where i.is_active and (i.store is null or i.store = keys.store)
                       and (i.weekdays is null or extract(isodow from keys.work_date)::smallint = any(i.weekdays)))),
           coalesce(c.n, 0), c.who, c.at, coalesce(nn.cnt, 0), coalesce(nn.unconf, 0)
    from keys
    left join public.checklist_days d on d.work_date = keys.work_date and d.store = keys.store
    left join c  on c.work_date  = keys.work_date and c.store  = keys.store
    left join nn on nn.work_date = keys.work_date and nn.store = keys.store
    where public.is_store_manager()
    order by keys.work_date desc, keys.store
$$;
