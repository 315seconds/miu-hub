-- 매장 업무 매뉴얼 + 일일 체크리스트 + 특이사항 메모
-- 적용: supabase db query --linked -f scripts/store-manual-20261029.sql   (그다음 store-manual-seed-20261029.sql)
--
-- 쓰는 사람: 매장직원 3명(전수지·천현수·정경환) + 관리자 2명(황태훈·최영훈). 화면은 `manual/`.
-- 권한(서버 강제, profiles.id 고정):
--   직원 = 매뉴얼·체크리스트 읽기, 오늘 체크 표시, 오늘 메모 작성(본인 메모는 당일 삭제)
--   관리자 = 위 전부 + 매뉴얼·체크리스트 항목 편집 + 메모 "확인" 표시 + 날짜별 현황 조회
--   그 외 로그인 직원은 이 기능의 테이블을 읽지도 못한다.
--   전수지 = 73630cc7-b03a-4eed-8b36-be0962209b3d / 천현수 = 60cc2609-1d88-4e28-b6f6-83de357eb193 / 정경환 = 8b059176-454b-4a07-b067-1449c04a31d1
--   황태훈 = 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d / 최영훈 = e3781795-f971-4227-9ef3-2cc6d31b358c
--
-- 기록 규칙:
--   체크·메모는 (날짜, 매장) 단위로 공유한다. 같은 매장을 두 명이 맡아도 한 장. 누가 체크했는지(checked_by)·누가 썼는지(author)는 로그인 이름으로 서버가 박는다.
--   날짜는 서버 KST 오늘만 쓴다(지난 날 체크·메모를 나중에 고칠 수 없음).
--   항목(checklist_items)은 지우지 않고 is_active=false 로 숨긴다(지난 기록의 항목 참조 유지).
--   checklist_days.total_items = 그날 마지막 체크 시점에 그 매장에 적용되던 활성 항목 수(항목을 나중에 바꿔도 지난 날 달성률이 흔들리지 않게).

-- ── 권한 함수 ────────────────────────────────────────────────
create or replace function public.is_store_staff()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '73630cc7-b03a-4eed-8b36-be0962209b3d'::uuid,
        '60cc2609-1d88-4e28-b6f6-83de357eb193'::uuid,
        '8b059176-454b-4a07-b067-1449c04a31d1'::uuid
    )
$$;

create or replace function public.is_store_manager()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid,
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid
    )
$$;

create or replace function public.store_manual_can_use()
returns boolean
language sql stable security definer set search_path = public as $$
    select public.is_store_staff() or public.is_store_manager()
$$;

-- 화면용: 'manager' | 'staff' | null
create or replace function public.store_manual_role()
returns text
language sql stable security definer set search_path = public as $$
    select case when public.is_store_manager() then 'manager'
                when public.is_store_staff() then 'staff' end
$$;

create or replace function public.store_today()
returns date
language sql stable set search_path = public as $$
    select (now() at time zone 'Asia/Seoul')::date
$$;

-- 로그인 계정 이름(없으면 예외). 기록자 이름은 항상 이걸로 박는다.
create or replace function public.store_manual_name()
returns text
language plpgsql stable security definer set search_path = public as $$
declare v_name text;
begin
    select p.name into v_name from public.profiles p where p.id = auth.uid();
    if v_name is null or btrim(v_name) = '' then
        raise exception '계정에 이름이 설정돼 있지 않아요. 관리자에게 요청해 주세요.' using errcode = 'P0001';
    end if;
    return v_name;
end
$$;

-- ── 매뉴얼 글 ────────────────────────────────────────────────
create table if not exists public.manual_articles (
    id          uuid primary key default gen_random_uuid(),
    category    text not null check (btrim(category) <> ''),   -- 상황별 대처 / 키오스크 / 운영 안내 …
    title       text not null check (btrim(title) <> ''),
    body        text not null default '',                       -- 평문. 줄바꿈 그대로 보여준다
    sort_order  integer not null default 0,
    is_active   boolean not null default true,
    updated_by  text,
    updated_at  timestamptz not null default now()
);
create index if not exists manual_articles_cat_idx on public.manual_articles (category, sort_order);

-- ── 체크리스트 항목 ──────────────────────────────────────────
create table if not exists public.checklist_items (
    id          uuid primary key default gen_random_uuid(),
    store       text,                                           -- null = 전 매장 공통, 아니면 locations.name
    grp         text not null check (btrim(grp) <> ''),         -- 장비 점검 / 청소 / …
    content     text not null check (btrim(content) <> ''),
    sort_order  integer not null default 0,
    is_active   boolean not null default true,
    updated_by  text,
    updated_at  timestamptz not null default now()
);
create index if not exists checklist_items_store_idx on public.checklist_items (store, sort_order);

-- 편집 기록(이름·시각)은 서버가 박는다
create or replace function public.store_manual_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is not null then   -- 서버 작업(시드·service_role)은 이름 없이 통과
        new.updated_by := public.store_manual_name();
    end if;
    new.updated_at := now();
    return new;
end
$$;
drop trigger if exists store_manual_touch on public.manual_articles;
create trigger store_manual_touch before insert or update on public.manual_articles
    for each row execute function public.store_manual_touch();
drop trigger if exists store_manual_touch on public.checklist_items;
create trigger store_manual_touch before insert or update on public.checklist_items
    for each row execute function public.store_manual_touch();

-- ── 일일 기록 ────────────────────────────────────────────────
create table if not exists public.checklist_days (
    work_date    date not null,
    store        text not null,
    total_items  integer not null,
    primary key (work_date, store)
);

create table if not exists public.checklist_checks (
    work_date   date not null,
    store       text not null,
    item_id     uuid not null references public.checklist_items(id),
    checked_by  text not null,
    checked_at  timestamptz not null default now(),
    primary key (work_date, store, item_id)
);

create table if not exists public.store_notes (
    id            uuid primary key default gen_random_uuid(),
    work_date     date not null,
    store         text not null,
    author_id     uuid not null,
    author        text not null,
    body          text not null check (btrim(body) <> '' and char_length(body) <= 2000),
    created_at    timestamptz not null default now(),
    confirmed_by  text,                                         -- 관리자가 확인한 표시
    confirmed_at  timestamptz
);
create index if not exists store_notes_date_idx on public.store_notes (work_date desc, store);

-- ── RLS: 읽기는 5명, 쓰기는 RPC(직원 기록) / 관리자 정책(편집) ──────────
alter table public.manual_articles  enable row level security;
alter table public.checklist_items  enable row level security;
alter table public.checklist_days   enable row level security;
alter table public.checklist_checks enable row level security;
alter table public.store_notes      enable row level security;

drop policy if exists manual_articles_select on public.manual_articles;
create policy manual_articles_select on public.manual_articles
    for select to authenticated using (public.store_manual_can_use());
drop policy if exists manual_articles_write on public.manual_articles;
create policy manual_articles_write on public.manual_articles
    for all to authenticated using (public.is_store_manager()) with check (public.is_store_manager());

drop policy if exists checklist_items_select on public.checklist_items;
create policy checklist_items_select on public.checklist_items
    for select to authenticated using (public.store_manual_can_use());
drop policy if exists checklist_items_write on public.checklist_items;
create policy checklist_items_write on public.checklist_items
    for all to authenticated using (public.is_store_manager()) with check (public.is_store_manager());

drop policy if exists checklist_days_select on public.checklist_days;
create policy checklist_days_select on public.checklist_days
    for select to authenticated using (public.store_manual_can_use());
drop policy if exists checklist_checks_select on public.checklist_checks;
create policy checklist_checks_select on public.checklist_checks
    for select to authenticated using (public.store_manual_can_use());
drop policy if exists store_notes_select on public.store_notes;
create policy store_notes_select on public.store_notes
    for select to authenticated using (public.store_manual_can_use());

-- 새 테이블 grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md) 준수. 항목은 숨기기만(delete 없음), 글은 delete 가능.
revoke all on public.manual_articles, public.checklist_items, public.checklist_days, public.checklist_checks, public.store_notes from anon, authenticated;
grant select, insert, update, delete on public.manual_articles to authenticated;
grant select, insert, update on public.checklist_items to authenticated;
grant select on public.checklist_days, public.checklist_checks, public.store_notes to authenticated;
grant select, insert, update, delete on public.manual_articles, public.checklist_items, public.checklist_days, public.checklist_checks, public.store_notes to service_role;

-- ── 직원 기록 RPC ────────────────────────────────────────────
-- 체크 표시/해제. 오늘(KST)만. 이미 체크된 항목을 다시 체크해도 처음 체크한 사람·시각을 유지한다.
create or replace function public.checklist_set(p_store text, p_item uuid, p_checked boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_today date := public.store_today();
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
    if not exists (select 1 from public.checklist_items i
                   where i.id = p_item and i.is_active and (i.store is null or i.store = p_store)) then
        raise exception '이 매장에 없는 체크 항목이에요.' using errcode = 'P0001';
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
    where i.is_active and (i.store is null or i.store = p_store);
    insert into public.checklist_days (work_date, store, total_items)
    values (v_today, p_store, v_total)
    on conflict (work_date, store) do update set total_items = excluded.total_items;
end
$$;

create or replace function public.store_note_add(p_store text, p_body text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    v_id uuid;
begin
    if not public.store_manual_can_use() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    if not exists (select 1 from public.locations l where l.name = p_store and l.is_active) then
        raise exception '알 수 없는 매장이에요: %', p_store using errcode = 'P0001';
    end if;
    insert into public.store_notes (work_date, store, author_id, author, body)
    values (public.store_today(), p_store, auth.uid(), public.store_manual_name(), btrim(p_body))
    returning id into v_id;
    return v_id;
end
$$;

-- 본인 메모는 쓴 날 안에만 삭제(관리자는 언제든)
create or replace function public.store_note_delete(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if not public.store_manual_can_use() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    delete from public.store_notes n
    where n.id = p_id
      and (public.is_store_manager() or (n.author_id = auth.uid() and n.work_date = public.store_today()));
    if not found then
        raise exception '삭제할 수 없는 메모예요(본인이 오늘 쓴 메모만 삭제 가능).' using errcode = 'P0001';
    end if;
end
$$;

-- ── 관리자 RPC ───────────────────────────────────────────────
create or replace function public.store_note_confirm(p_id uuid, p_confirmed boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if not public.is_store_manager() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    update public.store_notes
    set confirmed_by = case when p_confirmed then public.store_manual_name() end,
        confirmed_at = case when p_confirmed then now() end
    where id = p_id;
    if not found then
        raise exception '메모를 찾을 수 없어요.' using errcode = 'P0001';
    end if;
end
$$;

-- 기간 요약: (날짜, 매장)마다 체크 n/total, 마지막 체크한 사람, 메모 수, 미확인 메모 수. 기록이 있는 (날짜, 매장)만 나온다.
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
                     where i.is_active and (i.store is null or i.store = keys.store))),
           coalesce(c.n, 0), c.who, c.at, coalesce(nn.cnt, 0), coalesce(nn.unconf, 0)
    from keys
    left join public.checklist_days d on d.work_date = keys.work_date and d.store = keys.store
    left join c  on c.work_date  = keys.work_date and c.store  = keys.store
    left join nn on nn.work_date = keys.work_date and nn.store = keys.store
    where public.is_store_manager()
    order by keys.work_date desc, keys.store
$$;

revoke all on function
    public.is_store_staff(), public.is_store_manager(), public.store_manual_can_use(), public.store_manual_role(),
    public.store_today(), public.store_manual_name(), public.store_manual_touch(),
    public.checklist_set(text, uuid, boolean), public.store_note_add(text, text), public.store_note_delete(uuid),
    public.store_note_confirm(uuid, boolean), public.store_checklist_overview(date, date)
from public, anon;
grant execute on function
    public.is_store_staff(), public.is_store_manager(), public.store_manual_can_use(), public.store_manual_role(),
    public.store_today(), public.store_manual_name(),
    public.checklist_set(text, uuid, boolean), public.store_note_add(text, text), public.store_note_delete(uuid),
    public.store_note_confirm(uuid, boolean), public.store_checklist_overview(date, date)
to authenticated, service_role;
