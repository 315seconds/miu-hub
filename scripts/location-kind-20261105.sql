-- 위치 종류(locations.kind) 통합 — 화면마다 코드에 박혀 있던 위치 목록(창고·제외·비매장)을 DB 한 곳으로
-- 적용: supabase db query --linked -f scripts/location-kind-20261105.sql   (stocktake-missing-flag-20261105.sql 이 먼저 적용돼 있어야 함)
--
-- kind
--   store     매장(철수해도 store. 철수 여부는 is_active 로 구분)
--   warehouse 창고·물류(공동물류, 온라인, 재봉합성수, 재봉합부천)
--   final     최종 처리 위치: 더 이상 우리 물건이 아님(폐기, 위탁종료). 여기 오면 재고가 disposed 가 된다.
--   temp      옛 임시 위치(날짜+재고조사 등, 이제 새로 만들지 않음). 목록에서 숨김.
-- 새 위치는 통합 관리에서 종류를 골라 만든다. 화면은 이 컬럼만 읽는다(코드에 위치 이름 목록을 두지 말 것).

begin;

alter table public.locations add column if not exists kind text not null default 'store';
alter table public.locations drop constraint if exists locations_kind_check;
alter table public.locations add constraint locations_kind_check check (kind in ('store', 'warehouse', 'final', 'temp'));

-- 위치 이름은 물건(inventory_items.location)과 문자열로 이어지므로 유일해야 한다
create unique index if not exists locations_name_key on public.locations (name);

-- 기존 위치 분류
update public.locations set kind = 'warehouse' where name in ('공동물류', '온라인', '재봉합성수', '재봉합부천');
update public.locations set kind = 'final'     where name in ('폐기', '위탁종료');
update public.locations set kind = 'temp'      where public.is_pseudo_location(name);

-- 최종 위치 위탁종료 등록(이동앱 목적지로 선택 가능, 재고조사·매장 목록에는 안 나옴)
insert into public.locations (name, is_active, kind)
select '위탁종료', true, 'final' where not exists (select 1 from public.locations where name = '위탁종료');

-- 최종 위치 판별(트리거가 쓴다): locations 에서 읽으므로 위치를 코드에 박지 않는다
create or replace function public.is_final_location(p text) returns boolean
language sql stable security definer set search_path = '' as $fn$
    select exists (select 1 from public.locations l where l.name = p and l.kind = 'final')
$fn$;
revoke all on function public.is_final_location(text), public.is_pseudo_location(text) from public, anon;
grant execute on function public.is_final_location(text), public.is_pseudo_location(text) to authenticated, service_role;

-- 폐기 트리거: 하드코딩 ('폐기','위탁종료') → is_final_location()
create or replace function public.inventory_items_sync_disposed()
returns trigger language plpgsql set search_path = 'public' as $fn$
declare v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
    if public.is_final_location(new.location) then
        if new.status = 'in_stock' then new.status := 'disposed'; end if;
    elsif tg_op = 'UPDATE' and public.is_final_location(old.location) and new.status = 'disposed' then
        new.status := 'in_stock';   -- 최종 위치에서 나감
    end if;

    if tg_op = 'INSERT' then
        if public.is_pseudo_location(new.location) and new.status = 'in_stock' and new.missing_since is null then
            new.missing_since := v_today;
            new.miss_count := greatest(new.miss_count, 1);
        end if;
    elsif new.location is distinct from old.location then
        if public.is_pseudo_location(new.location) and new.status = 'in_stock' then
            new.missing_since := coalesce(new.missing_since, v_today);
            new.miss_count := greatest(new.miss_count, 1);
            if not public.is_pseudo_location(old.location) then
                new.missing_from := coalesce(new.missing_from, old.location);
            end if;
        else
            new.missing_since := null; new.missing_from := null; new.missing_session_id := null; new.miss_count := 0;
        end if;
    end if;
    if new.status <> 'in_stock' then
        new.missing_since := null; new.missing_from := null; new.missing_session_id := null; new.miss_count := 0;
    end if;
    return new;
end $fn$;

-- 위치 보호: 이름 변경 금지(물건과 문자열로 이어짐), 최종 위치 삭제·종류 변경 금지, 재고가 남은 위치 삭제 금지
create or replace function public.locations_guard() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
    if tg_op = 'DELETE' then
        if old.kind = 'final' then
            raise exception '최종 처리 위치(%)는 삭제할 수 없어요.', old.name using errcode = 'P0001';
        end if;
        if exists (select 1 from public.inventory_items i where i.location = old.name and i.status = 'in_stock') then
            raise exception '"%"에 재고가 남아 있어서 삭제할 수 없어요. 먼저 물건을 옮기거나 비활성으로 두세요.', old.name using errcode = 'P0001';
        end if;
        return old;
    end if;
    if new.name is distinct from old.name then
        raise exception '위치 이름은 바꿀 수 없어요. (물건의 위치 값과 이어져 있어요)' using errcode = 'P0001';
    end if;
    if old.kind = 'final' and new.kind is distinct from old.kind then
        raise exception '최종 처리 위치의 종류는 바꿀 수 없어요.' using errcode = 'P0001';
    end if;
    if new.kind = 'final' and old.kind is distinct from new.kind then
        raise exception '최종 처리 위치는 DB에서 직접 만들어야 해요. (재고가 폐기 상태로 바뀌는 중요한 위치예요)' using errcode = 'P0001';
    end if;
    return new;
end $fn$;
drop trigger if exists locations_guard on public.locations;
create trigger locations_guard before update or delete on public.locations for each row execute function public.locations_guard();

commit;
