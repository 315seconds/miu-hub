-- 재고조사 종합 보고서(xlsx)용 보조 데이터(읽기 전용)
-- 적용: supabase db query --linked -f scripts/stocktake-report-20261113.sql
--   lost_by_location : 지난 조사 시작 ~ 이번 조사 시작 사이(지난 조사가 없으면 90일) 출처 '택분실'로 입고된 물건을 현재 위치별로 센 건수·금액
--                      (stocktake_reference 와 같은 기간 기준). 보고서의 "미스캔 − 택분실 입고 = 분실 추정" 계산에 쓴다.
--   last_moved       : 이번 조사 미스캔 물건별 마지막으로 승인된 이동일(KST). 이동 이력이 없으면 키가 없다.

create or replace function public.stocktake_report_data(p_session uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare v_start timestamptz; v_prev record; v_from timestamptz; v_lost jsonb; v_moved jsonb;
begin
    perform public.stocktake_require_user();
    select started_at into v_start from public.stocktake_sessions where id = p_session;
    if v_start is null then return null; end if;
    select started_at into v_prev from public.stocktake_sessions
     where status = 'closed' and started_at < v_start order by started_at desc limit 1;
    v_from := coalesce(v_prev.started_at, v_start - interval '90 days');
    select coalesce(jsonb_agg(jsonb_build_object('location', x.location, 'n', x.n, 'amount', x.amt) order by x.location), '[]'::jsonb) into v_lost
      from (select i.location, count(*) n, coalesce(sum(i.price), 0) amt
              from public.inventory_items i
             where i.source = '택분실' and i.created_at > v_from and i.created_at <= v_start
             group by i.location) x;
    select coalesce(jsonb_object_agg(x.barcode, x.d), '{}'::jsonb) into v_moved
      from (select r.barcode, max((m.approved_at at time zone 'Asia/Seoul')::date) d
              from public.stocktake_results r
              join public.session_items si on upper(btrim(si.barcode)) = r.barcode
              join public.move_sessions m on m.id = si.session_id and m.status = 'approved' and m.approved_at is not null
             where r.session_id = p_session and r.kind = 'missing'
             group by r.barcode) x;
    return jsonb_build_object('lost_by_location', v_lost, 'last_moved', v_moved);
end
$fn$;
revoke all on function public.stocktake_report_data(uuid) from public, anon;
grant execute on function public.stocktake_report_data(uuid) to authenticated;
