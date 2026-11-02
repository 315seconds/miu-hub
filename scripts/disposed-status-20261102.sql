-- 폐기를 "위치 폐기"와 함께 "상태 disposed"로도 관리한다.
-- 적용: supabase db query --linked -f scripts/disposed-status-20261102.sql
--
-- 규칙(트리거 inventory_items_sync_disposed가 위치·상태가 바뀔 때마다 적용; 이동앱 승인 → VM이 DB 위치를 쓰는 경로도, 엑셀 동기화·수동 수정도 같은 규칙):
--   위치가 '폐기'가 되면 재고(in_stock)는 disposed 가 된다. 판매됨(sold)은 그대로 둔다.
--   위치가 '폐기'에서 다른 곳으로 나가면 disposed 는 in_stock 으로 돌아온다(폐기에서 복구).
--   위치가 '폐기'인 물건의 상태를 in_stock 으로 쓰는 경로(VM 환불 복구 등)는 disposed 로 고정한다.
-- 위치 '폐기'는 그대로 둔다: 엑셀 입고시트에는 위치 칸만 있고 상태 칸이 없어, 지우면 엑셀과 DB가 어긋난다.
-- 상태 '미보유'(택분실 교환 처리)는 그 작업을 할 때 같은 제약에 추가한다.
-- 사입 통계의 폐기 판정(purchase_items_v.disposed)은 이제 상태 disposed 한 곳을 본다.

alter table public.inventory_items drop constraint if exists inventory_items_status_check;
alter table public.inventory_items add constraint inventory_items_status_check
    check (status = any (array['in_stock'::text, 'sold'::text, 'disposed'::text]));

create or replace function public.inventory_items_sync_disposed()
returns trigger
language plpgsql set search_path = public as $$
begin
    if new.location = '폐기' then
        if new.status = 'in_stock' then
            new.status := 'disposed';
        end if;
    elsif tg_op = 'UPDATE' and old.location = '폐기' and new.status = 'disposed' then
        new.status := 'in_stock';   -- 폐기에서 나감
    end if;
    return new;
end $$;

drop trigger if exists inventory_items_sync_disposed on public.inventory_items;
create trigger inventory_items_sync_disposed
    before insert or update of location, status on public.inventory_items
    for each row execute function public.inventory_items_sync_disposed();

-- 기존 폐기 위치 재고를 상태 disposed 로. 대상 수와 갱신 수가 다르면 롤백.
do $$
declare n_target int; n_done int;
begin
    select count(*) into n_target from public.inventory_items where location = '폐기' and status = 'in_stock';
    update public.inventory_items set status = 'disposed' where location = '폐기' and status = 'in_stock';
    get diagnostics n_done = row_count;
    if n_done <> n_target then
        raise exception '폐기 상태 변환: 대상 % 건, 갱신 % 건 — 롤백', n_target, n_done;
    end if;
    raise notice '폐기 상태 변환: % 건', n_done;
end $$;

-- 사입 통계: 폐기 판정을 위치 문자열에서 상태로(원가·수량 규칙은 그대로)
create or replace view public.purchase_items_v with (security_invoker = true) as
with inv as (
    select distinct on (upper(btrim(barcode))) upper(btrim(barcode)) as barcode, price, location, source, status
    from public.inventory_items
    where upper(btrim(barcode)) in (select barcode from public.purchase_batch_items)
    order by upper(btrim(barcode)), created_at desc
)
select b.barcode,
       b.batch_id,
       b.initial_price,
       coalesce(i.price, b.last_known_price, b.initial_price) as current_price,
       b.category,
       b.excluded,
       (not b.excluded and coalesce(i.status, '') = 'disposed') as disposed,
       -- 물건의 출처. 한 차시에 여러 출처가 섞일 수 있다(예: 에코옥션 차시에 야후옥션 물건 10벌). 허브에 없거나 출처가 빈 옛 물건은 차시의 출처로 본다.
       coalesce(nullif(i.source, ''), s.name) as item_source
from public.purchase_batch_items b
join public.purchase_batches pb on pb.id = b.batch_id
join public.sources s on s.id = pb.source_id
left join inv i on i.barcode = b.barcode;
