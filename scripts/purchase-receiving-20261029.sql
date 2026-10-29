-- 입고 화면의 차시 선택: 행거에 "출처 + 회차"를 붙여 두면, 입고 승인으로 바코드가 발급되는 순간 사입 차시 물건으로 자동 등록된다.
-- 의류/잡화는 직원이 고르지 않는다. 물건 카테고리가 의류면 그 회차의 의류 차시, 의류가 아니면(봉투·위탁·폐기 제외) 같은 회차의 잡화 차시로 들어간다.
-- 적용 순서: purchase-stats-20261029.sql → (엑셀 이관) → 이 파일 → receiving/js/session.js 배포
--   (이 파일이 먼저 적용돼 있어야 입고 화면의 차시 선택이 동작한다. 화면은 차시 테이블이 없어도 기존처럼 동작하도록 만들어 둠)
--
-- 최초 프라이싱 = 바코드가 발급되는 시점(승인)의 inventory_items.price. 이후 가격수정은 원가 안분에 영향을 주지 않는다.
-- approve_inventory_session 은 건드리지 않는다(그 함수가 inventory_items.barcode 를 채울 때 트리거가 따라 동작).
-- 트리거가 실패해도 입고 승인은 막지 않는다(경고만 남김). 누락된 물건은 사입 통계 > 점검 > "차시 미배정"에 나온다.

alter table public.inventory_hangers
    add column if not exists purchase_batch_id uuid references public.purchase_batches(id);

-- 카테고리 → 차시 종류. '의류' / '잡화' / null(차시 집계에서 제외).
--   앞의 '온'(온라인) 접두는 떼고 본다. 의류 목록에 없는 새 카테고리는 잡화로 가니, 의류 카테고리가 새로 생기면 여기에 추가한다.
create or replace function public.purchase_item_kind(p_category text)
returns text
language sql immutable as $$
    select case
        when c = '' then '의류'
        when c in ('봉투', '위탁', '폐기') then null
        when c in ('반팔티', '긴팔티', '티셔츠', '나시티', '민소매', '스웻셔츠', '스웻', '스웨터', '셔츠', 'PK', 'PK셔츠',
                   '블라우스', '자켓', '바람막이', '플리스', '원피스', '스커트', '긴바지', '반바지', '트랙팬츠', '셋업',
                   '하와이안셔츠', '반필티', '키즈', 'C', 'C반팔티') then '의류'
        else '잡화'
    end
    from (select regexp_replace(upper(btrim(coalesce(p_category, ''))), '^온', '') as c) x
$$;

create or replace function public.purchase_attach_item()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
    v_hanger_batch uuid; v_kind text; v_src uuid; v_round text; v_target uuid;
begin
    if new.barcode is null or btrim(new.barcode) = '' or new.hanger_id is null then
        return new;
    end if;
    select h.purchase_batch_id into v_hanger_batch from public.inventory_hangers h where h.id = new.hanger_id;
    if v_hanger_batch is null then
        return new;
    end if;
    v_kind := public.purchase_item_kind(new.category);
    if v_kind is null then
        return new;   -- 봉투 등은 차시 집계에서 제외
    end if;
    select pb.source_id, pb.round_code into v_src, v_round from public.purchase_batches pb where pb.id = v_hanger_batch;
    -- 같은 회차에서 이 종류의 차시. 없으면(옛 회차처럼 의류/잡화를 나누지 않은 경우) 행거에 붙은 차시 그대로.
    select pb.id into v_target from public.purchase_batches pb
     where pb.source_id = v_src and pb.round_code = v_round and pb.kind = v_kind;
    insert into public.purchase_batch_items (barcode, batch_id, initial_price, category)
    values (upper(btrim(new.barcode)), coalesce(v_target, v_hanger_batch), coalesce(new.price, 0), new.category)
    on conflict (barcode) do nothing;
    return new;
exception when others then
    raise warning 'purchase_attach_item 실패(%): %', new.barcode, sqlerrm;
    return new;
end $$;

drop trigger if exists purchase_attach_item on public.inventory_items;
create trigger purchase_attach_item
    after insert or update of barcode on public.inventory_items
    for each row execute function public.purchase_attach_item();
