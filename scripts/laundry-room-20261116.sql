-- 세탁실 현황 · 세탁/수선 완료 · 바코드 재출력 대기열 (docs/PLAN_택분실등록_세탁실_20261116.md 3단계)
-- 적용: supabase db query --linked -f scripts/laundry-room-20261116.sql   (위치 `세탁실`은 0단계로 이미 있음)
--
-- 흐름: 세탁·수선을 보낼 때 이동앱으로 `세탁실`로 옮긴다 → laundry_list()가 위치가 세탁실인 재고를 보낸 위치·경과일과 보여 준다
--       → 돌아오면 laundry_complete()가 `세탁실 → 보낸 위치` 이동 세션을 보낸 위치별로 만들고(재출력 필요 건은 reprint_queue에 올림)
--       → 재출력 화면이 대기열을 불러와 출력하면 reprint_queue_mark_printed()가 대기열에서 뺀다.
-- 보낸 위치 = move_sessions·session_items 이력에서 그 바코드가 마지막으로 세탁실로 갈 때(승인된 세션)의 출발 위치. 이력이 없으면 호출자가 p_fallback으로 지정한다.
-- 이동 세션은 기존 파이프라인 그대로(당일 pending → 22:00 자동 승인 → VM이 DB·엑셀 반영). 완료 처리한 물건은 VM 반영 전까지 목록에서 빠진다.
-- 위치 이름 `세탁실`은 이 파일과 laundry/index.html 에만 둔다(창고 종류만으로는 구분할 수 없다).

begin;

-- 1) 재출력 대기열: 세탁 완료가 넣고 재출력 화면이 비운다. 쓰기는 RPC·service_role만.
create table if not exists public.reprint_queue (
    id         uuid primary key default gen_random_uuid(),
    barcode    text not null,
    queued_by  text not null,
    queued_at  timestamptz not null default now(),
    printed_at timestamptz
);
create unique index if not exists reprint_queue_open_barcode on public.reprint_queue (barcode) where printed_at is null;

alter table public.reprint_queue enable row level security;
drop policy if exists reprint_queue_select on public.reprint_queue;
create policy reprint_queue_select on public.reprint_queue for select to authenticated using (true);

revoke all on public.reprint_queue from anon, authenticated;
grant select on public.reprint_queue to authenticated;
grant select, insert, update, delete on public.reprint_queue to service_role;

-- 2) 세탁실 현황: 위치가 세탁실인 재고 + 보낸 날짜·보낸 위치·경과일. 이미 완료 처리해 이동 대기 중인 물건은 뺀다.
create or replace function public.laundry_list()
returns table (barcode text, brand text, category text, product_name text, price integer, photo_url text,
               sent_date date, sent_from text, days integer)
language sql stable set search_path = '' as $fn$
    select i.barcode, i.brand, i.category, i.product_name, i.price, i.photo_url,
           l.session_date, l.from_location, (public.store_today() - l.session_date)::integer
    from public.inventory_items i
    left join lateral (
        select ms.session_date, ms.from_location
        from public.session_items si
        join public.move_sessions ms on ms.id = si.session_id
        where si.barcode = i.barcode and si.is_submitted and not coalesce(si.is_error, false)
          and ms.to_location = '세탁실' and ms.status in ('approved', 'processed')
        order by ms.session_date desc, si.scanned_at desc
        limit 1
    ) l on true
    where auth.uid() is not null
      and i.status = 'in_stock' and i.location = '세탁실'
      and not exists (
          select 1 from public.session_items si2
          join public.move_sessions ms2 on ms2.id = si2.session_id
          where si2.barcode = i.barcode and si2.is_submitted and not coalesce(si2.is_error, false)
            and ms2.from_location = '세탁실' and (ms2.status = 'pending' or (ms2.status = 'approved' and not coalesce(ms2.excel_updated, false))))
    order by l.session_date asc nulls first, i.barcode
$fn$;

-- 3) 세탁·수선 완료: 세탁실 → 보낸 위치 이동 세션(보낸 위치별) + 재출력 대기열.
--    p_fallback = {"<바코드>": "<보낸 위치>"} — 이력이 없는 바코드의 보낸 위치(활성 매장·창고만).
create or replace function public.laundry_complete(p_barcodes text[], p_need_reprint boolean default true, p_fallback jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare
    v_name text; v_bad text; v_targets jsonb; v_dest record; v_sid uuid; v_n int;
    v_moved int := 0; v_sessions int := 0; v_queued int := 0;
begin
    v_name := public.stocktake_login_name();   -- 로그인 직원이고 이름이 있어야 한다
    if p_barcodes is null or cardinality(p_barcodes) = 0 then
        raise exception '완료할 물건을 골라 주세요.' using errcode = 'P0001';
    end if;
    if jsonb_typeof(coalesce(p_fallback, '{}'::jsonb)) <> 'object' then
        raise exception '보낸 위치 형식이 올바르지 않아요.' using errcode = 'P0001';
    end if;
    -- 22:00 자동 승인은 당일 pending만 승인한다. 그 뒤에 만든 세션은 승인되지 않고 만료돼 이동이 조용히 사라진다.
    if (now() at time zone 'Asia/Seoul')::time >= time '22:00' then
        raise exception '22시 이후에는 이동이 자동 승인되지 않아요. 내일 다시 완료 처리해 주세요.' using errcode = 'P0001';
    end if;
    perform pg_advisory_xact_lock(hashtext('laundry_complete'));   -- 같은 물건을 동시에 두 번 완료 처리하지 않도록

    -- 요청한 바코드가 전부 "세탁실의 재고이고 아직 완료 처리 안 됨"인지
    select string_agg(b, ', ') into v_bad
    from (select distinct b from unnest(p_barcodes) b) r
    where not exists (select 1 from public.laundry_list() l where l.barcode = r.b);
    if v_bad is not null then
        raise exception '세탁실에 없거나 이미 완료 처리된 물건이에요: %', v_bad using errcode = 'P0001';
    end if;

    -- 바코드별 보낸 위치: 이력의 출발 위치(지금 쓰는 매장·창고일 때만) → 아니면 p_fallback(같은 조건)
    select jsonb_agg(jsonb_build_object('barcode', x.barcode, 'dest', x.dest, 'product_name', coalesce(x.product_name, ''),
                                        'category', coalesce(x.category, ''), 'price', coalesce(x.price::text, '')))
      into v_targets
    from (
        select l.barcode, l.product_name, l.category, l.price,
               (select lo.name from public.locations lo
                 where lo.is_active and lo.kind in ('store', 'warehouse') and lo.name <> '세탁실'
                   and lo.name in (l.sent_from, btrim(p_fallback ->> l.barcode))
                 order by (lo.name = l.sent_from) desc
                 limit 1) as dest
        from public.laundry_list() l
        where l.barcode in (select distinct b from unnest(p_barcodes) b)
    ) x;

    select string_agg(t.barcode, ', ') into v_bad
    from jsonb_to_recordset(v_targets) as t(barcode text, dest text)
    where t.dest is null;
    if v_bad is not null then
        raise exception '보낸 위치를 알 수 없는 물건이에요. 위치를 직접 골라 주세요: %', v_bad using errcode = 'P0001';
    end if;

    for v_dest in
        select distinct t.dest from jsonb_to_recordset(v_targets) as t(barcode text, dest text)
    loop
        insert into public.move_sessions (session_date, from_location, to_location, status, created_by)
        values (public.store_today(), '세탁실', v_dest.dest, 'pending', v_name)
        returning id into v_sid;

        insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
        select v_sid, t.barcode, t.product_name, t.category, t.price, '세탁실', v_name, true, false
        from jsonb_to_recordset(v_targets) as t(barcode text, dest text, product_name text, category text, price text)
        where t.dest = v_dest.dest;
        get diagnostics v_n = row_count;
        v_moved := v_moved + v_n;
        v_sessions := v_sessions + 1;
    end loop;

    if coalesce(p_need_reprint, false) then
        insert into public.reprint_queue (barcode, queued_by)
        select t.barcode, v_name from jsonb_to_recordset(v_targets) as t(barcode text, dest text)
        on conflict (barcode) where printed_at is null do nothing;
        get diagnostics v_queued = row_count;
    end if;

    return jsonb_build_object('moved', v_moved, 'sessions', v_sessions, 'queued', v_queued);
end
$fn$;

-- 4) 재출력 완료 표시
create or replace function public.reprint_queue_mark_printed(p_barcodes text[])
returns integer language plpgsql security definer set search_path = '' as $fn$
declare v_n int;
begin
    perform public.stocktake_login_name();
    update public.reprint_queue set printed_at = now()
     where printed_at is null and barcode = any (coalesce(p_barcodes, '{}'));
    get diagnostics v_n = row_count;
    return v_n;
end
$fn$;

revoke all on function public.laundry_list(), public.laundry_complete(text[], boolean, jsonb), public.reprint_queue_mark_printed(text[]) from public, anon;
grant execute on function public.laundry_list(), public.laundry_complete(text[], boolean, jsonb), public.reprint_queue_mark_printed(text[]) to authenticated, service_role;

commit;
