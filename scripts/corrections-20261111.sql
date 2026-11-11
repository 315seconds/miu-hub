-- 정정 체계 1단계: 판매 정정 이력(corrections) + 정정 RPC 2개 + 재동기화 방어 트리거
-- 적용: supabase db query --linked -f scripts/corrections-20261111.sql
--
-- 원칙: DB가 원본. 정정은 RPC 한 번에(판매 기록·재고 상태·이력이 한 트랜잭션), 바꾸기 전 값은 이력에 남긴다.
-- 권한: 정정 RPC는 김민지·최영훈·황태훈만(서버 강제, profiles.id 고정). 이력은 로그인 직원 전체가 읽는다. 이력은 추가만 가능(수정·삭제 거부).
-- 환불·재판매: sold_items 는 바코드당 1행(UNIQUE) 그대로 둔다. 환불 기록이 있는 판매 행은 정정 RPC가 거부한다(사람이 판단).
-- 2단계(출처 수정·엑셀 반영 큐)·3단계(택분실 교환·화면)는 이 파일에 없다. 그때 kind 목록(CHECK)에 값을 추가한다.
--   김민지 = 428a5bfc-da1f-41c4-877e-9f6e5c787291 / 최영훈 = e3781795-f971-4227-9ef3-2cc6d31b358c / 황태훈 = 46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d

create or replace function public.is_correction_user()
returns boolean
language sql stable security definer set search_path = public as $$
    select auth.uid() in (
        '428a5bfc-da1f-41c4-877e-9f6e5c787291'::uuid,
        'e3781795-f971-4227-9ef3-2cc6d31b358c'::uuid,
        '46bd11c5-d6a6-4d71-8a3a-1f062c9ca69d'::uuid
    )
$$;

create table if not exists public.corrections (
    id              bigint generated always as identity primary key,
    kind            text not null check (kind in ('sale_barcode', 'sale_exclude')),
    barcode         text not null,          -- 정정 대상(원래) 바코드
    related_barcode text,                   -- 정정 후 바코드(sale_barcode)
    sold_date       date,
    before          jsonb not null,         -- 바꾸기 전 값(판매 행·재고 상태)
    after           jsonb,
    reason          text not null check (btrim(reason) <> ''),
    created_by      text not null,
    created_at      timestamptz not null default now()
);
create index if not exists corrections_key_idx on public.corrections (barcode, sold_date);
create index if not exists corrections_related_idx on public.corrections (related_barcode);

create or replace function public.corrections_immutable()
returns trigger language plpgsql as $$
begin
    raise exception 'corrections 는 추가만 가능합니다(수정·삭제 불가)' using errcode = '42501';
end $$;
drop trigger if exists corrections_immutable on public.corrections;
create trigger corrections_immutable before update or delete on public.corrections
    for each row execute function public.corrections_immutable();

alter table public.corrections enable row level security;
drop policy if exists corrections_read on public.corrections;
create policy corrections_read on public.corrections for select to authenticated using (true);
revoke all on public.corrections from public, anon;
grant select on public.corrections to authenticated, service_role;

-- ── 정정 RPC ────────────────────────────────────────────────

-- 팔린 바코드 정정: (원래 바코드, 판매일)의 판매 행을 다른 바코드로 옮긴다. 택갈이(택 바코드 → 실제 물건), 입력 오타(CR0347 → CR03347).
--   새 가격(p_new_price)은 판매 가격만 바꾼다. 물건의 현재가는 가격수정 앱에서.
create or replace function public.correct_sale_barcode(
    p_from text, p_sold_date date, p_to text, p_reason text, p_new_price integer default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_name text;
    v_from text := upper(btrim(p_from));
    v_to   text := upper(btrim(p_to));
    v_sale public.sold_items%rowtype;
    v_to_item public.inventory_items%rowtype;
    v_from_item public.inventory_items%rowtype;
    v_price integer;
    v_pn text;
    v_id bigint;
begin
    if not public.is_correction_user() then raise exception 'forbidden' using errcode = '42501'; end if;
    if p_reason is null or btrim(p_reason) = '' then raise exception '사유를 입력하세요' using errcode = '22023'; end if;
    if v_from = v_to then raise exception '같은 바코드로는 정정할 수 없어요' using errcode = '22023'; end if;
    select name into v_name from public.profiles where id = auth.uid();
    if v_name is null or btrim(v_name) = '' then raise exception '프로필 이름이 없어 정정할 수 없어요' using errcode = 'P0001'; end if;

    select * into v_sale from public.sold_items where upper(btrim(barcode)) = v_from and sold_date = p_sold_date for update;
    if not found then raise exception '판매 기록이 없어요: % (%)', v_from, p_sold_date using errcode = 'P0001'; end if;
    if v_sale.refund_date is not null then
        raise exception '환불 기록이 있는 판매는 정정할 수 없어요(%). 제외 또는 별도 처리를 하세요', v_from using errcode = 'P0001';
    end if;
    select * into v_to_item from public.inventory_items where upper(btrim(barcode)) = v_to;
    if not found then raise exception '재고에 없는 바코드예요: %', v_to using errcode = 'P0001'; end if;
    if exists (select 1 from public.sold_items where upper(btrim(barcode)) = v_to) then
        raise exception '이미 판매 기록이 있는 바코드예요: %', v_to using errcode = 'P0001';
    end if;
    select * into v_from_item from public.inventory_items where upper(btrim(barcode)) = v_from;   -- 오타 바코드는 재고에 없을 수 있다

    v_price := coalesce(p_new_price, v_sale.price);
    v_pn := coalesce(nullif(btrim(v_to_item.product_name), ''), v_to || ' ' || coalesce(v_to_item.category, ''));

    perform set_config('app.correcting', '1', true);   -- 방어 트리거가 이 정정 자신을 되돌리지 않게
    update public.sold_items set barcode = v_to, product_name = v_pn, price = v_price where id = v_sale.id;
    update public.inventory_items set status = 'sold' where id = v_to_item.id and status = 'in_stock';
    if v_from_item.id is not null and v_from_item.status = 'sold' then
        update public.inventory_items set status = 'in_stock' where id = v_from_item.id;   -- 폐기 위치면 트리거가 disposed 로
    end if;
    perform set_config('app.correcting', '', true);

    insert into public.corrections (kind, barcode, related_barcode, sold_date, before, after, reason, created_by)
    values ('sale_barcode', v_from, v_to, p_sold_date,
            jsonb_build_object('sale', to_jsonb(v_sale),
                               'from_item_status', v_from_item.status, 'to_item_status', v_to_item.status),
            jsonb_build_object('barcode', v_to, 'price', v_price, 'product_name', v_pn),
            btrim(p_reason), v_name)
    returning id into v_id;
    return jsonb_build_object('correction_id', v_id, 'from', v_from, 'to', v_to, 'sold_date', p_sold_date, 'price', v_price);
end $$;

-- 판매 제외: 잘못 들어온 판매 행을 지운다(반품·중복결제·오입력). 재고가 sold 로 남아 있으면 p_restore_stock 에 따라 in_stock 으로 되돌린다.
create or replace function public.exclude_sale(
    p_barcode text, p_sold_date date, p_reason text, p_restore_stock boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_name text;
    v_bc text := upper(btrim(p_barcode));
    v_sale public.sold_items%rowtype;
    v_item public.inventory_items%rowtype;
    v_id bigint;
begin
    if not public.is_correction_user() then raise exception 'forbidden' using errcode = '42501'; end if;
    if p_reason is null or btrim(p_reason) = '' then raise exception '사유를 입력하세요' using errcode = '22023'; end if;
    select name into v_name from public.profiles where id = auth.uid();
    if v_name is null or btrim(v_name) = '' then raise exception '프로필 이름이 없어 정정할 수 없어요' using errcode = 'P0001'; end if;

    select * into v_sale from public.sold_items where upper(btrim(barcode)) = v_bc and sold_date = p_sold_date for update;
    if not found then raise exception '판매 기록이 없어요: % (%)', v_bc, p_sold_date using errcode = 'P0001'; end if;
    select * into v_item from public.inventory_items where upper(btrim(barcode)) = v_bc;

    perform set_config('app.correcting', '1', true);
    delete from public.sold_items where id = v_sale.id;
    if p_restore_stock and v_item.id is not null and v_item.status = 'sold' then
        update public.inventory_items set status = 'in_stock' where id = v_item.id;
    end if;
    perform set_config('app.correcting', '', true);

    insert into public.corrections (kind, barcode, sold_date, before, reason, created_by)
    values ('sale_exclude', v_bc, p_sold_date,
            jsonb_build_object('sale', to_jsonb(v_sale), 'item_status', v_item.status, 'restore_stock', p_restore_stock),
            btrim(p_reason), v_name)
    returning id into v_id;
    return jsonb_build_object('correction_id', v_id, 'barcode', v_bc, 'sold_date', p_sold_date);
end $$;

revoke execute on function public.is_correction_user(), public.correct_sale_barcode(text, date, text, text, integer),
    public.exclude_sale(text, date, text, boolean) from public, anon;
grant execute on function public.is_correction_user(), public.correct_sale_barcode(text, date, text, text, integer),
    public.exclude_sale(text, date, text, boolean) to authenticated, service_role;

-- ── 재동기화 방어 ───────────────────────────────────────────
-- sold_sync 가 정정 전 바코드로 같은 판매를 다시 넣으려 하면(수동 재실행, resync_sold_items.py) 정정된 바코드·가격으로 바꿔 받고,
-- 제외한 판매는 받지 않는다. VM 코드는 고치지 않는다. 정정은 한 단계만 따라간다(정정 뒤 다시 정정하면 이력의 마지막 것).
create or replace function public.sold_items_apply_corrections()
returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.corrections%rowtype;
begin
    if current_setting('app.correcting', true) = '1' then return new; end if;
    select * into c from public.corrections
     where kind in ('sale_barcode', 'sale_exclude') and barcode = upper(btrim(new.barcode)) and sold_date = new.sold_date
     order by id desc limit 1;
    if not found then return new; end if;
    if c.kind = 'sale_exclude' then
        if tg_op = 'INSERT' then return null; end if;   -- 제외한 판매는 받지 않음
        return old;                                     -- 수정으로 제외 키가 되려 하면 무시
    end if;
    new.barcode := c.related_barcode;
    new.price := coalesce((c.after ->> 'price')::integer, new.price);
    new.product_name := coalesce(c.after ->> 'product_name', new.product_name);
    return new;
end $$;
drop trigger if exists sold_items_apply_corrections on public.sold_items;
create trigger sold_items_apply_corrections
    before insert or update of barcode, sold_date on public.sold_items
    for each row execute function public.sold_items_apply_corrections();

-- VM 이 판매를 올린 뒤 원래(택) 바코드의 재고를 sold 로 patch 하는 경로는 sold_items 트리거로 못 막으므로 여기서 막는다:
-- 정정으로 판매가 다른 바코드로 옮겨 간 바코드가, 판매 행이 없는데 sold 로 바뀌려 하면 상태를 유지한다.
create or replace function public.inventory_items_guard_corrected_sale()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if new.status = 'sold' and old.status is distinct from 'sold'
       and exists (select 1 from public.corrections c where c.kind = 'sale_barcode' and c.barcode = upper(btrim(new.barcode)))
       and not exists (select 1 from public.sold_items s where upper(btrim(s.barcode)) = upper(btrim(new.barcode))) then
        new.status := old.status;
    end if;
    return new;
end $$;
drop trigger if exists inventory_items_guard_corrected_sale on public.inventory_items;
create trigger inventory_items_guard_corrected_sale
    before update of status on public.inventory_items
    for each row execute function public.inventory_items_guard_corrected_sale();
