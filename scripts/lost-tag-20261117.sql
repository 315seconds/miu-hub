-- 택분실 등록 · 수령 · 바코드 매칭 (docs/PLAN_택분실등록_세탁실_20261116.md 1단계)
-- 적용: supabase db query --linked -f scripts/lost-tag-20261117.sql   (store-manual-20261029.sql·laundry-room-20261116.sql 이 먼저 적용돼 있어야 함)
--
-- 흐름: 매장 직원이 허브 `manual/` 체크리스트에서 택분실 등록(사진 2칸+메모) → 김민지(관리자)가 `lost-tag/`에서 수령 확인 → 사진에서 원래 바코드를 찾아 매칭
--       → 바코드의 DB 위치 → 최종 보관 위치로 이동 세션을 바로 만든다(22:00 자동 승인 → VM이 DB·엑셀 반영) → 재출력 → 새 택.
-- 못 찾은 건의 신규입고(status 'new_entry')는 2단계에서 만든다. 컬럼·상태값은 지금 미리 둔다.
-- 권한(서버 강제): 등록 = store_manual_can_use()(매장 직원 3 + 관리자 4). 수령·매칭·취소 = is_admin().
--   조회·사진 열람 = 위 둘 중 하나. 김민지는 매장 업무 권한이 없어 관리자 쪽으로만 처리한다.
-- 사진은 비공개 버킷 lost-tags(photos/<uuid>.jpg). 취소·수정 시 사진은 지우지 않는다(수정·사진 교체 기능 없음: 잘못 올렸으면 취소 후 다시 등록).
-- 위치 이름 `세탁실`은 최종 위치 후보에서 빼려고만 쓴다(laundry-room 과 같은 값).

begin;

create table if not exists public.lost_tag_items (
    id              uuid primary key default gen_random_uuid(),
    store           text not null,                                  -- 발견 지점 = locations.name
    reported_by     text not null,
    reported_at     timestamptz not null default now(),
    photo_front     text not null,                                  -- 칸1 전면(필수)
    photo_label     text,                                           -- 칸2 라벨·로고(선택)
    note            text not null default '',
    status          text not null default 'registered'
                    check (status in ('registered', 'received', 'identified', 'new_entry', 'cancelled')),
    received_by     text,
    received_at     timestamptz,
    matched_barcode text,
    final_location  text,
    move_session_id uuid references public.move_sessions(id) on delete set null,
    new_item_barcode text,                                          -- 2단계
    new_session_id  uuid,                                           -- 2단계
    resolved_by     text,                                           -- 매칭·신규입고·취소를 한 사람
    resolved_at     timestamptz
);
create index if not exists lost_tag_items_status_reported on public.lost_tag_items (status, reported_at);
-- 같은 바코드를 두 건에 매칭하지 않는다
create unique index if not exists lost_tag_items_matched_barcode on public.lost_tag_items (upper(matched_barcode)) where status = 'identified';

alter table public.lost_tag_items enable row level security;
drop policy if exists lost_tag_items_select on public.lost_tag_items;
create policy lost_tag_items_select on public.lost_tag_items for select to authenticated
    using (public.is_admin() or public.store_manual_can_use());

revoke all on public.lost_tag_items from anon, authenticated;
grant select on public.lost_tag_items to authenticated;
grant select, insert, update, delete on public.lost_tag_items to service_role;

-- ── 저장소(비공개) ───────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lost-tags', 'lost-tags', false, 10485760, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['image/jpeg'];

drop policy if exists lost_tags_select on storage.objects;
create policy lost_tags_select on storage.objects for select to authenticated
    using (bucket_id = 'lost-tags' and (public.is_admin() or public.store_manual_can_use()));
drop policy if exists lost_tags_insert on storage.objects;
create policy lost_tags_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'lost-tags' and public.store_manual_can_use() and (storage.foldername(name))[1] = 'photos');

-- ── 등록 ─────────────────────────────────────────────────────
-- 사진을 먼저 photos/<uuid>.jpg 로 올린 뒤 호출한다. p_label 은 없으면 null.
create or replace function public.lost_tag_register(p_store text, p_note text, p_front text, p_label text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_label text := nullif(btrim(coalesce(p_label, '')), '');
begin
    if not public.store_manual_can_use() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    if p_store is null or not exists (select 1 from public.locations l where l.name = p_store and l.kind = 'store' and l.is_active) then
        raise exception '등록할 수 없는 매장이에요.' using errcode = 'P0001';
    end if;
    if length(coalesce(p_note, '')) > 1000 then
        raise exception '메모는 1000자까지 적을 수 있어요.' using errcode = 'P0001';
    end if;
    if p_front is null or p_front !~ '^photos/[0-9a-f-]{36}\.jpg$' or (v_label is not null and v_label !~ '^photos/[0-9a-f-]{36}\.jpg$') then
        raise exception '사진 경로가 올바르지 않아요.' using errcode = 'P0001';
    end if;
    if v_label is not null and v_label = p_front then
        raise exception '전면 사진과 라벨 사진이 같은 파일이에요.' using errcode = 'P0001';
    end if;
    if (select count(distinct o.name) from storage.objects o where o.bucket_id = 'lost-tags' and o.name in (p_front, coalesce(v_label, p_front)))
         <> (1 + (v_label is not null)::int) then
        raise exception '올린 사진 파일을 찾지 못했어요. 다시 올려 주세요.' using errcode = 'P0001';
    end if;
    insert into public.lost_tag_items (store, reported_by, photo_front, photo_label, note)
    values (p_store, public.store_manual_name(), p_front, v_label, btrim(coalesce(p_note, '')))
    returning id into v_id;
    return v_id;
end
$$;

-- ── 수령 확인(registered → received) ─────────────────────────
create or replace function public.lost_tag_receive(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
    if not public.is_admin() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    v_name := public.stocktake_login_name();
    update public.lost_tag_items set status = 'received', received_by = v_name, received_at = now()
     where id = p_id and status = 'registered';
    if not found then
        raise exception '수령 확인할 수 없는 건이에요(이미 처리됐거나 취소됐어요).' using errcode = 'P0001';
    end if;
end
$$;

-- ── 매칭(received → identified) ──────────────────────────────
-- 바코드의 DB 위치 → 최종 보관 위치로 이동 세션을 바로 만든다(같은 날 제출 순서 문제를 피하려고). 이미 그 위치면 세션 없이 기록만 한다.
-- 최종 위치 = 활성 창고(세탁실 제외). 22:00 이후에는 이동이 자동 승인되지 않으므로(만료) 이동이 필요한 매칭을 거절한다.
create or replace function public.lost_tag_match(p_id uuid, p_barcode text, p_final text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_name text; v_row public.lost_tag_items; v_item record; v_b text := upper(btrim(coalesce(p_barcode, ''))); v_sid uuid;
begin
    if not public.is_admin() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    v_name := public.stocktake_login_name();
    if v_b = '' then
        raise exception '바코드를 입력해 주세요.' using errcode = 'P0001';
    end if;
    select * into v_row from public.lost_tag_items where id = p_id for update;
    if not found or v_row.status <> 'received' then
        raise exception '수령 확인이 끝난 건만 매칭할 수 있어요.' using errcode = 'P0001';
    end if;
    select i.barcode, i.status, i.location, i.product_name, i.category, i.price into v_item
      from public.inventory_items i where upper(btrim(i.barcode)) = v_b limit 1;
    if not found then
        raise exception '재고에 없는 바코드예요: %', v_b using errcode = 'P0001';
    end if;
    if v_item.status <> 'in_stock' then
        raise exception '보유중이 아닌 바코드예요(%): %', v_item.status, v_item.barcode using errcode = 'P0001';
    end if;
    if exists (select 1 from public.lost_tag_items t where t.status = 'identified' and upper(t.matched_barcode) = upper(v_item.barcode)) then
        raise exception '이미 다른 택분실 건에 매칭된 바코드예요: %', v_item.barcode using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.locations l where l.name = p_final and l.kind = 'warehouse' and l.is_active and l.name <> '세탁실') then
        raise exception '최종 보관 위치를 창고에서 골라 주세요.' using errcode = 'P0001';
    end if;

    if v_item.location is distinct from p_final then
        if (now() at time zone 'Asia/Seoul')::time >= time '22:00' then
            raise exception '22시 이후에는 이동이 자동 승인되지 않아요. 내일 다시 매칭해 주세요.' using errcode = 'P0001';
        end if;
        if coalesce(btrim(v_item.location), '') = '' then
            raise exception '바코드의 현재 위치가 비어 있어 이동을 만들 수 없어요: %', v_item.barcode using errcode = 'P0001';
        end if;
        insert into public.move_sessions (session_date, from_location, to_location, status, created_by)
        values (public.store_today(), v_item.location, p_final, 'pending', v_name)
        returning id into v_sid;
        insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
        values (v_sid, v_item.barcode, coalesce(v_item.product_name, ''), coalesce(v_item.category, ''), coalesce(v_item.price::text, ''), v_item.location, v_name, true, false);
    end if;

    update public.lost_tag_items
       set status = 'identified', matched_barcode = v_item.barcode, final_location = p_final, move_session_id = v_sid,
           resolved_by = v_name, resolved_at = now()
     where id = p_id;
    return jsonb_build_object('barcode', v_item.barcode, 'from', v_item.location, 'to', p_final, 'session_id', v_sid);
end
$$;

-- ── 취소(registered/received → cancelled) ────────────────────
create or replace function public.lost_tag_cancel(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
    if not public.is_admin() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    v_name := public.stocktake_login_name();
    update public.lost_tag_items set status = 'cancelled', resolved_by = v_name, resolved_at = now()
     where id = p_id and status in ('registered', 'received');
    if not found then
        raise exception '취소할 수 없는 건이에요(이미 처리됐어요).' using errcode = 'P0001';
    end if;
end
$$;

revoke all on function public.lost_tag_register(text, text, text, text), public.lost_tag_receive(uuid),
    public.lost_tag_match(uuid, text, text), public.lost_tag_cancel(uuid) from public, anon;
grant execute on function public.lost_tag_register(text, text, text, text), public.lost_tag_receive(uuid),
    public.lost_tag_match(uuid, text, text), public.lost_tag_cancel(uuid) to authenticated, service_role;

commit;
