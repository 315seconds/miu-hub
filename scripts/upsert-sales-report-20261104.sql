-- 매출 리포트 한 건(+ 상품 단위 행들)을 원자적으로 저장하는 함수. VM 작업 monthly_report.py(매월 1일 성수 본점 리포트 자동 생성)가 service_role 로 호출한다.
-- 적용: supabase db query --linked -f scripts/upsert-sales-report-20261104.sql
--
-- 허브 화면 저장(report/js/save-report.js: upsert → 아이템 삭제 → 아이템 삽입, 세 요청)과 같은 결과를 한 트랜잭션으로 낸다:
--   같은 지점·종류·기간(store, report_type, start_date, end_date)의 리포트가 있으면 id를 유지한 채 덮어쓰고, 기존 아이템은 모두 지운 뒤 p_items 로 바꾼다.
-- p_report = analyzeReport() 결과(_items 제외), p_items = 그 _items 배열. 로그인한 사용자·anon 은 부를 수 없다(service_role 전용).

create or replace function public.upsert_sales_report(p_report jsonb, p_items jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
    insert into public.sales_reports (store, report_type, start_date, end_date, location, label, total_sales, cash_sales, total_cnt,
                                      daily_avg_sales, dom_sales, dom_cnt, dom_share, for_sales, for_cnt, foreign_share, peak_hour,
                                      peak_sales, top_category, hourly_data, top_categories, foreign_keywords)
    values (p_report->>'store', p_report->>'report_type', (p_report->>'start_date')::date, (p_report->>'end_date')::date,
            p_report->>'location', p_report->>'label', (p_report->>'total_sales')::bigint, (p_report->>'cash_sales')::integer,
            (p_report->>'total_cnt')::integer, (p_report->>'daily_avg_sales')::bigint, (p_report->>'dom_sales')::bigint,
            (p_report->>'dom_cnt')::integer, (p_report->>'dom_share')::numeric, (p_report->>'for_sales')::bigint,
            (p_report->>'for_cnt')::integer, (p_report->>'foreign_share')::numeric, (p_report->>'peak_hour')::smallint,
            (p_report->>'peak_sales')::bigint, p_report->>'top_category', p_report->'hourly_data', p_report->'top_categories',
            array(select jsonb_array_elements_text(p_report->'foreign_keywords')))
    on conflict (store, report_type, start_date, end_date) do update set
        location = excluded.location, label = excluded.label, total_sales = excluded.total_sales, cash_sales = excluded.cash_sales,
        total_cnt = excluded.total_cnt, daily_avg_sales = excluded.daily_avg_sales, dom_sales = excluded.dom_sales,
        dom_cnt = excluded.dom_cnt, dom_share = excluded.dom_share, for_sales = excluded.for_sales, for_cnt = excluded.for_cnt,
        foreign_share = excluded.foreign_share, peak_hour = excluded.peak_hour, peak_sales = excluded.peak_sales,
        top_category = excluded.top_category, hourly_data = excluded.hourly_data, top_categories = excluded.top_categories,
        foreign_keywords = excluded.foreign_keywords, updated_at = now()
    returning id into v_id;

    delete from public.sales_report_items where report_id = v_id;
    insert into public.sales_report_items (report_id, transaction_time, barcode, category, category_base, is_online, is_foreign,
                                           item_amount, approved_amount, card_issuer)
    select v_id, (e->>'transaction_time')::timestamptz, e->>'barcode', e->>'category', e->>'category_base',
           (e->>'is_online')::boolean, (e->>'is_foreign')::boolean, (e->>'item_amount')::numeric, (e->>'approved_amount')::bigint,
           e->>'card_issuer'
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e;
    return v_id;
end
$$;

revoke all on function public.upsert_sales_report(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.upsert_sales_report(jsonb, jsonb) to service_role;
