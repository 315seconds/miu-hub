-- 재고조사 결과 화면 참고 수치(읽기 전용)
-- 적용: supabase db query --linked -f scripts/stocktake-reference-20261111.sql
--   lost_count : 지난 조사 시작 ~ 이번 조사 시작 사이에 출처 '택분실'로 입고된 물건 수(inventory_items.created_at 기준).
--                지난 조사(닫힌 조사)가 없으면 이번 조사 시작 전 90일.
--   in_stock / flagged : 조회 시점의 재고(in_stock) 수와 그중 미확인 표시 수.
-- 택분실 짝 매칭은 하지 않는다(2026-11-11 결정). 미스캔 수와 이 수량을 사람이 비교해 판단한다.

create or replace function public.stocktake_reference(p_session uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_start timestamptz; v_prev record; v_from timestamptz; v_lost int; v_stock int; v_flag int;
begin
    perform public.stocktake_require_user();
    select started_at into v_start from public.stocktake_sessions where id = p_session;
    if v_start is null then return null; end if;
    select id, session_date, started_at into v_prev from public.stocktake_sessions
     where status = 'closed' and started_at < v_start order by started_at desc limit 1;
    v_from := coalesce(v_prev.started_at, v_start - interval '90 days');
    select count(*) into v_lost from public.inventory_items i
     where i.source = '택분실' and i.created_at > v_from and i.created_at <= v_start;
    select count(*), count(*) filter (where i.missing_since is not null) into v_stock, v_flag
      from public.inventory_items i where i.status = 'in_stock';
    return jsonb_build_object('prev_date', v_prev.session_date, 'lost_count', v_lost, 'in_stock', v_stock, 'flagged', v_flag);
end
$fn$;
revoke all on function public.stocktake_reference(uuid) from public, anon;
grant execute on function public.stocktake_reference(uuid) to authenticated;
