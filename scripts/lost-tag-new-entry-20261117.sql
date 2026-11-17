-- 택분실 신규입고: 원래 바코드를 못 찾은 건을 새 바코드로 입고 (docs/PLAN_택분실등록_세탁실_20261116.md 2단계)
-- 적용: supabase db query --linked -f scripts/lost-tag-new-entry-20261117.sql   (lost-tag-20261117.sql 이 먼저 적용돼 있어야 함)
--
-- 한 RPC가 기존 입고 흐름을 서버에서 그대로 따라간다(클라이언트 호출 순서를 재사용하지 않는 이유: 세션·행거·물건·승인이 중간에 끊기면 빈 세션이나 미승인 세션이 남는다):
--   inventory_sessions(pending) → inventory_hangers(source '택분실', 제출됨) → inventory_items(사진·브랜드·카테고리·가격)
--   → approve_inventory_session(바코드 발급: 공동물류 A+YY+6자리, 온라인 U+YYMM+4자리) → (최종 위치가 입고 위치와 다르면) 이동 세션.
-- 이후는 기존 길: VM inventory_process가 엑셀에 기록(P열 출처 택분실) → 라벨 출력. 승인자 = 처리한 관리자 이름.
-- 물건 사진은 칸1 사진을 클라이언트가 공개 버킷 inventory-photos 로 복사한 URL로 받는다(비공개 버킷 파일은 서버에서 복사할 수 없다).
-- 입고 위치는 next_barcode()가 알고 있는 두 곳(공동물류·온라인)만 된다(그 함수가 위치 이름을 직접 비교한다).
-- 22:00 KST 이후에는 이동이 필요한 경우(최종 위치 ≠ 입고 위치)만 거절한다(이동 세션은 22:00 자동 승인이 당일 pending만 승인).

create or replace function public.lost_tag_new_entry(
    p_id uuid, p_entry text, p_final text, p_brand text, p_category text, p_price integer, p_photo_url text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
    v_name text; v_row public.lost_tag_items; v_final text := coalesce(nullif(btrim(p_final), ''), p_entry);
    v_photo text; v_sid uuid; v_hid uuid; v_item uuid; v_appr jsonb; v_bc text; v_msid uuid;
begin
    if not public.is_admin() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    v_name := public.stocktake_login_name();
    select * into v_row from public.lost_tag_items where id = p_id for update;
    if not found or v_row.status <> 'received' then
        raise exception '수령 확인이 끝난 건만 신규입고할 수 있어요.' using errcode = 'P0001';
    end if;
    if p_entry not in ('공동물류', '온라인')
       or not exists (select 1 from public.locations l where l.name = p_entry and l.kind = 'warehouse' and l.is_active) then
        raise exception '입고 위치는 공동물류 또는 온라인만 고를 수 있어요.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from public.locations l where l.name = v_final and l.kind = 'warehouse' and l.is_active and l.name <> '세탁실') then
        raise exception '최종 보관 위치를 창고에서 골라 주세요.' using errcode = 'P0001';
    end if;
    if coalesce(btrim(p_category), '') = '' then
        raise exception '카테고리를 골라 주세요.' using errcode = 'P0001';
    end if;
    if p_price is null or p_price <= 0 then
        raise exception '가격을 입력해 주세요.' using errcode = 'P0001';
    end if;
    -- 사진: 공개 버킷 inventory-photos 에 실제로 있는 파일의 공개 URL만
    v_photo := regexp_replace(coalesce(p_photo_url, ''), '\s+', '', 'g');
    if v_photo !~ '^https://[^/]+/storage/v1/object/public/inventory-photos/[^?#]+$'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'inventory-photos'
                      and o.name = regexp_replace(v_photo, '^https://[^/]+/storage/v1/object/public/inventory-photos/', '')) then
        raise exception '물건 사진을 찾지 못했어요. 다시 시도해 주세요.' using errcode = 'P0001';
    end if;
    if v_final <> p_entry and (now() at time zone 'Asia/Seoul')::time >= time '22:00' then
        raise exception '22시 이후에는 이동이 자동 승인되지 않아요. 내일 다시 입고하거나 최종 위치를 입고 위치와 같게 해 주세요.' using errcode = 'P0001';
    end if;

    insert into public.inventory_sessions (session_date, barcode_prefix, location, online_toggle, created_by, status, notes)
    values (public.store_today(), case when p_entry = '온라인' then 'U' else 'A' end, p_entry, p_entry = '온라인', v_name, 'pending', '택분실 신규입고')
    returning id into v_sid;
    insert into public.inventory_hangers (session_id, hanger_number, category, is_online, submitted_by, submitted_at, source)
    values (v_sid, '택분실', '', p_entry = '온라인', v_name, now(), '택분실')
    returning id into v_hid;
    insert into public.inventory_items (hanger_id, session_id, price, brand, order_index, location, category, photo_url)
    values (v_hid, v_sid, p_price, nullif(btrim(coalesce(p_brand, '')), ''), 0, p_entry, btrim(p_category), v_photo);

    v_appr := public.approve_inventory_session(v_sid);   -- 바코드 발급 + 승인(이 호출자의 이름)
    v_bc := v_appr ->> 'first';

    if v_final <> p_entry then
        insert into public.move_sessions (session_date, from_location, to_location, status, created_by)
        values (public.store_today(), p_entry, v_final, 'pending', v_name)
        returning id into v_msid;
        insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
        values (v_msid, v_bc, '', btrim(p_category), p_price::text, p_entry, v_name, true, false);
    end if;

    update public.lost_tag_items
       set status = 'new_entry', new_item_barcode = v_bc, new_session_id = v_sid, final_location = v_final, move_session_id = v_msid,
           resolved_by = v_name, resolved_at = now()
     where id = p_id;
    return jsonb_build_object('barcode', v_bc, 'session_id', v_sid, 'move_session_id', v_msid, 'location', p_entry, 'final', v_final);
end
$$;

revoke all on function public.lost_tag_new_entry(uuid, text, text, text, text, integer, text) from public, anon;
grant execute on function public.lost_tag_new_entry(uuid, text, text, text, text, integer, text) to authenticated, service_role;
