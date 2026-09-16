// analyze.js — app.py 로직 이관
// 해외판정 · 온라인판정 · 매출배분 · 시간대집계 · TOP3

const DEFAULT_FOREIGN_KEYWORDS = ['해외', '오렌지스퀘어', '알리페이', '위챗페이'];
const EXCLUDED_CATEGORIES = new Set(['C', '위탁']);

// ─── 해외 판정 (normalize_tx) ─────────────────────────────────
function makeForeignDetector(keywords) {
  const kws = (keywords || []).map(k => String(k).trim()).filter(Boolean);
  if (kws.length === 0) return () => false;
  // 정규식 특수문자 이스케이프
  const pattern = kws
    .map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join('|');
  const re = new RegExp(pattern);
  return (cardIssuer) => re.test(String(cardIssuer || ''));
}

// ─── 온라인 판정 (cat_flags) ──────────────────────────────────
// 소분류 앞글자가 '온'이면 온라인
// 반환: { base: 온 제거된 카테고리, isOnline: bool }
function catFlags(raw) {
  const c = String(raw || '').trim();
  const isOnline = c.startsWith('온');
  const base = (isOnline ? c.slice(1) : c).trim();
  return { base, isOnline };
}

// ─── 카테고리 제외 (is_excluded_category) ─────────────────────
function isExcludedCategory(base) {
  return EXCLUDED_CATEGORIES.has(String(base || '').trim());
}

// ─── 소모품 제외: 바코드 pb숫자 ────────────────────────────────
function isConsumable(barcode) {
  return /^pb\d+$/i.test(String(barcode || '').trim());
}

// ─── 필터/집계 대상 items 만들기 (explode_items 축소판) ───────
// 각 트랜잭션을 아이템별로 펼치고 매출 배분
function explodeItems(transactions, priceMap, categoryMap, isForeign) {
  const out = [];

  for (const tx of transactions) {
    const items = (tx.resolvedItems || []).filter(v => v && !String(v).startsWith('[미매칭]'));
    if (items.length === 0) continue;

    const approved = Number(tx.승인금액 || 0);
    const foreign = isForeign(tx.카드발급사명);

    // 각 바코드의 입고 단가
    const prices = items.map(bc => priceMap.get(bc));
    const known = prices.filter(p => p != null);
    const unknownCnt = prices.filter(p => p == null).length;
    const knownSum = known.reduce((s, p) => s + p, 0);

    let amounts;
    if (unknownCnt === 0) {
      // 전부 매칭 → 비율 스케일링
      if (knownSum === 0) {
        amounts = items.map(() => approved / items.length);
      } else {
        const scale = approved / knownSum;
        amounts = prices.map(p => p * scale);
      }
    } else {
      // 미매칭 있음 → 매칭된 것은 입고금액 그대로, 나머지는 잔액 균등배분
      const remainder = approved - knownSum;
      const fallback = unknownCnt ? (remainder / unknownCnt) : 0;
      amounts = prices.map(p => (p != null) ? p : fallback);
    }

    // 아이템별로 record 생성
    for (let i = 0; i < items.length; i++) {
      const bc = items[i];
      if (isConsumable(bc)) continue;  // 소모품 제외 (pb숫자)
      const rawCat = categoryMap.get(bc) || '미매칭';
      const { base, isOnline } = catFlags(rawCat);
      if (isExcludedCategory(base)) continue;  // C, 위탁 제외

      out.push({
        transaction_time: tx.거래일시,
        barcode: bc,
        category: rawCat,
        category_base: base,
        is_online: isOnline,
        is_foreign: foreign,
        item_amount: Number(amounts[i].toFixed(2)),
        approved_amount: approved,
        card_issuer: tx.카드발급사명,
      });
    }
  }

  return out;
}

// ─── 시간대별 집계 (build_hourly) ─────────────────────────────
// 반환: [{hour, 총매출, 국내매출, 해외매출, 거래건수}, ...]
function buildHourly(transactions, isForeign) {
  const byHour = {};
  for (let h = 0; h < 24; h++) {
    byHour[h] = { hour: h, 총매출: 0, 국내매출: 0, 해외매출: 0, 거래건수: 0 };
  }

  for (const tx of transactions) {
    const h = new Date(tx.거래일시).getHours();
    if (h < 0 || h > 23 || isNaN(h)) continue;
    const amt = Number(tx.승인금액 || 0);
    const foreign = isForeign(tx.카드발급사명);
    byHour[h].총매출 += amt;
    byHour[h].거래건수 += 1;
    if (foreign) byHour[h].해외매출 += amt;
    else         byHour[h].국내매출 += amt;
  }

  return Object.values(byHour);
}

// ─── 피크타임 (peak_hour) ─────────────────────────────────────
// 국내/해외/전체 각각의 시간대별 매출 최대인 시각
function peakHour(hourly, mode) {
  const key = mode === 'dom' ? '국내매출'
            : mode === 'for' ? '해외매출'
            : '총매출';
  let best = { hour: null, sales: 0 };
  for (const h of hourly) {
    if (h[key] > best.sales) best = { hour: h.hour, sales: h[key] };
  }
  return best;
}

// ─── 카테고리 TOP3 (top3_categories) ──────────────────────────
// items를 필터링 후 카테고리(base)별 count/추정매출 집계, 상위 3
function top3Categories(items, filter) {
  const filtered = items.filter(it => {
    if (filter.overseas != null && it.is_foreign !== filter.overseas) return false;
    if (filter.online != null && it.is_online !== filter.online) return false;
    return true;
  });

  const map = new Map();
  for (const it of filtered) {
    const cat = it.category_base;
    if (!map.has(cat)) map.set(cat, { 카테고리: cat, 수량: 0, 추정매출: 0 });
    const m = map.get(cat);
    m.수량 += 1;
    m.추정매출 += it.item_amount || 0;
  }

  return [...map.values()]
    .sort((a, b) => b.수량 - a.수량 || b.추정매출 - a.추정매출)
    .slice(0, 3)
    .map(r => ({ ...r, 추정매출: Math.round(r.추정매출) }));
}

// ─── KPI 집계 (메인 진입점) ───────────────────────────────────
function analyzeReport({
  transactions,
  ingoItems,
  storeLabel,
  startDate,
  endDate,
  foreignKeywords,
  location,
  reportType,
}) {
  const isForeign = makeForeignDetector(foreignKeywords);
  const priceMap = buildPriceMap(ingoItems);
  const categoryMap = buildCategoryMap(ingoItems);

  // 기간 필터
  const start = new Date(startDate + 'T00:00:00');
  const end = new Date(endDate + 'T23:59:59');
  const filteredTx = transactions.filter(t => {
    const d = new Date(t.거래일시);
    return d >= start && d <= end;
  });

  if (filteredTx.length === 0) {
    throw new Error('선택한 기간에 해당하는 거래가 없어요.');
  }

  // 매출 KPI
  const total_sales = filteredTx.reduce((s, t) => s + Number(t.승인금액 || 0), 0);
  const total_cnt = filteredTx.length;
  const for_txs = filteredTx.filter(t => isForeign(t.카드발급사명));
  const for_sales = for_txs.reduce((s, t) => s + Number(t.승인금액 || 0), 0);
  const for_cnt = for_txs.length;
  const dom_sales = total_sales - for_sales;
  const dom_cnt = total_cnt - for_cnt;
  const for_share = total_sales > 0 ? for_sales / total_sales : 0;
  const dom_share = total_sales > 0 ? dom_sales / total_sales : 0;

  // 시간대
  const hourly = buildHourly(filteredTx, isForeign);
  const peak_all = peakHour(hourly, 'all');
  const peak_dom = peakHour(hourly, 'dom');
  const peak_for = peakHour(hourly, 'for');

  // 아이템 explode + TOP3
  const items = explodeItems(filteredTx, priceMap, categoryMap, isForeign);
  const top = {
    all_gen: top3Categories(items, { overseas: null, online: false }),
    all_on : top3Categories(items, { overseas: null, online: true }),
    dom_gen: top3Categories(items, { overseas: false, online: false }),
    dom_on : top3Categories(items, { overseas: false, online: true }),
    for_gen: top3Categories(items, { overseas: true, online: false }),
    for_on : top3Categories(items, { overseas: true, online: true }),
  };

  // 일수 계산
  const days = Math.max(1, Math.floor((end - start) / 86400000) + 1);
  const daily_avg_sales = Math.round(total_sales / days);

  // top_category (전체 일반 TOP1)
  const top_category = (top.all_gen && top.all_gen[0]) ? top.all_gen[0].카테고리 : null;

  return {
    // 기본 메타
    store: storeLabel,
    report_type: reportType,
    start_date: startDate,
    end_date: endDate,
    location: location || null,
    label: reportType === 'main'
      ? startDate.slice(0, 7)  // "2026-08"
      : storeLabel,

    // KPI
    total_sales: Math.round(total_sales),
    total_cnt,
    daily_avg_sales,
    dom_sales: Math.round(dom_sales),
    dom_cnt,
    dom_share: Number(dom_share.toFixed(4)),
    for_sales: Math.round(for_sales),
    for_cnt,
    foreign_share: Number(for_share.toFixed(4)),
    peak_hour: peak_all.hour,
    peak_sales: peak_all.sales,
    top_category,

    // 상세 (JSONB)
    hourly_data: hourly,
    top_categories: top,

    // 스냅샷
    foreign_keywords: foreignKeywords,

    // 별도 반환 (인서트용)
    _items: items,
  };
}
