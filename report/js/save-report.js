// save-report.js — Supabase 저장 · view.html 리다이렉트

async function saveReport(reportData) {
  const items = reportData._items || [];
  const payload = { ...reportData };
  delete payload._items;

  // Supabase에 upsert (같은 지점·타입·기간 있으면 덮어씀)
  const { data, error } = await sb
    .from('sales_reports')
    .upsert(payload, {
      onConflict: 'store,report_type,start_date,end_date',
    })
    .select('id')
    .single();

  if (error) throw new Error(`리포트 저장 실패: ${error.message}`);
  const reportId = data.id;

  // 이전 아이템 삭제 (재생성 케이스)
  await sb.from('sales_report_items').delete().eq('report_id', reportId);

  // 아이템 인서트 (청크 나눠서)
  if (items.length > 0) {
    const CHUNK = 500;
    for (let i = 0; i < items.length; i += CHUNK) {
      const chunk = items.slice(i, i + CHUNK).map(it => ({
        report_id: reportId,
        transaction_time: it.transaction_time instanceof Date
          ? it.transaction_time.toISOString()
          : it.transaction_time,
        barcode: it.barcode,
        category: it.category,
        category_base: it.category_base,
        is_online: it.is_online,
        is_foreign: it.is_foreign,
        item_amount: it.item_amount,
        approved_amount: it.approved_amount,
        card_issuer: it.card_issuer,
      }));
      const { error: itErr } = await sb.from('sales_report_items').insert(chunk);
      if (itErr) throw new Error(`아이템 저장 실패 (${i}~${i+chunk.length}): ${itErr.message}`);
    }
  }

  return reportId;
}
