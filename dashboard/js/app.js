// ─── Constants ────────────────────────────────────────────────────────────────
const WAREHOUSE = ['공동물류', '온라인', '재봉합성수', '재봉합부천'];
const EXCLUDED  = ['폐기'];
const SOLD_PFX  = '공동판매';

const AGE_COLORS = { '0-30일': '#22c55e', '31-60일': '#f59e0b', '61-90일': '#f97316', '90일+': '#ef4444' };


// ─── State ────────────────────────────────────────────────────────────────────
let allLocations = [];
let activeCharts = {};
let expandedCat  = null;

// ─── Init ─────────────────────────────────────────────────────────────────────
async function init() {
  allLocations = await fetchLocations();
  renderSidebar();
  window.addEventListener('hashchange', route);
  await route();
}

// ─── Router ───────────────────────────────────────────────────────────────────
async function route() {
  showLoading(true);
  destroyCharts();
  expandedCat = null;
  const hash = location.hash || '#home';
  try {
    if (hash === '#home') {
      await renderHome();
    } else if (hash.startsWith('#loc/')) {
      await renderLocation(decodeURIComponent(hash.slice(5)));
    }
    updateFooter();
  } finally {
    showLoading(false);
  }
  highlightNav();
}

// ─── Sidebar ──────────────────────────────────────────────────────────────────
function renderSidebar() {
  const stores = allLocations.filter(l => !WAREHOUSE.includes(l.name));
  const wh     = allLocations.filter(l =>  WAREHOUSE.includes(l.name));

  document.getElementById('nav').innerHTML = `
    <div class="sidebar-section">
      ${navItem('#home', iconHome(), '전체 현황')}
    </div>
    <div class="sidebar-section">
      <div class="sidebar-section-label">매장</div>
      ${stores.map(l => navItem(`#loc/${enc(l.name)}`, iconDot(), l.name)).join('')}
    </div>
    ${wh.length ? `<div class="sidebar-section">
      <div class="sidebar-section-label">창고</div>
      ${wh.map(l => navItem(`#loc/${enc(l.name)}`, iconDot(), l.name + '<span class="tag-warehouse">창고</span>')).join('')}
    </div>` : ''}
  `;

  // 모바일 탭 바 렌더링
  const bar = document.getElementById('mobile-tab-bar');
  if (bar) {
    bar.innerHTML = [
      `<a class="mob-tab" href="#home">전체</a>`,
      ...stores.map(l => `<a class="mob-tab" href="#loc/${enc(l.name)}">${l.name}</a>`),
      ...wh.map(l => `<a class="mob-tab" href="#loc/${enc(l.name)}">${l.name} 창고</a>`),
    ].join('');
  }
}

function navItem(href, icon, label) {
  return `<a class="nav-item" href="${href}">${icon}${label}</a>`;
}

function highlightNav() {
  const cur = location.hash || '#home';
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('active', el.getAttribute('href') === cur);
  });
  document.querySelectorAll('.mob-tab').forEach(el => {
    const active = el.getAttribute('href') === cur;
    el.classList.toggle('active', active);
    if (active) el.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' });
  });
}

// ─── Home page ────────────────────────────────────────────────────────────────
async function renderHome() {
  const names  = allLocations.map(l => l.name);
  const stores = allLocations.filter(l => !WAREHOUSE.includes(l.name)).map(l => l.name);

  const [counts, oldCounts, sales] = await Promise.all([
    fetchCounts(names),
    fetchOldCounts(names, 90),
    fetchMonthlySales(names),
  ]);

  const totalStock   = counts.reduce((s, c) => s + c.count, 0);
  const totalRevenue = Object.values(sales).reduce((s, v) => s + v.revenue, 0);
  const totalOld     = oldCounts.reduce((s, c) => s + c.count, 0);
  const totalSold    = Object.values(sales).reduce((s, v) => s + v.count, 0);

  document.getElementById('content').innerHTML = `
    <div class="page-header">
      <div>
        <div class="page-title">전체 현황</div>
        <div class="page-sub">모든 매장 · 창고 통합 요약</div>
      </div>
      <button class="btn-refresh" onclick="route()">${iconRefresh()} 새로고침</button>
    </div>

    <div class="cards-row">
      <div class="stat-card stat-card-peach">
        <div class="stat-label">전체 재고</div>
        <div class="stat-value">${fmt(totalStock)}</div>
        <div class="stat-sub">모든 위치 합산</div>
      </div>
      <div class="stat-card stat-card-teal">
        <div class="stat-label">이달 매출</div>
        <div class="stat-value">${fmtMoney(totalRevenue)}</div>
        <div class="stat-sub">${thisMonth()} · ${fmt(totalSold)}건</div>
      </div>
      <div class="stat-card stat-card-pink">
        <div class="stat-label">장기재고 90일+</div>
        <div class="stat-value">${fmt(totalOld)}</div>
        <div class="stat-sub">전체 대비 ${totalStock ? pct(totalOld, totalStock) : '0%'}</div>
      </div>
      <div class="stat-card stat-card-lavender">
        <div class="stat-label">운영 매장</div>
        <div class="stat-value">${stores.length}</div>
        <div class="stat-sub">창고 ${WAREHOUSE.filter(w => names.includes(w)).length}개 별도</div>
      </div>
    </div>

    <div class="charts-row">
      <div class="section-card" style="margin-bottom:0">
        <h3>위치별 현재 재고</h3>
        <div class="chart-wrap"><canvas id="chart-stock"></canvas></div>
      </div>
      <div class="section-card" style="margin-bottom:0">
        <h3>이달 매장별 매출</h3>
        <div class="chart-wrap"><canvas id="chart-sales"></canvas></div>
      </div>
    </div>

    <div class="section-card" style="margin-top:18px">
      <h3>장기재고 현황 (90일 이상)</h3>
      ${renderOldTable(counts, oldCounts)}
    </div>
  `;

  drawStockChart(counts);
  drawSalesChart(stores, sales);
}

function renderOldTable(counts, oldCounts) {
  const rows = allLocations
    .map(l => ({
      name:  l.name,
      total: counts.find(c => c.name === l.name)?.count || 0,
      old:   oldCounts.find(c => c.name === l.name)?.count || 0,
    }))
    .filter(r => r.old > 0)
    .sort((a, b) => b.old - a.old);

  if (!rows.length) return '<div class="empty">90일 이상 장기재고 없음</div>';

  return `<div style="overflow-x:auto"><table>
    <thead><tr><th>위치</th><th>장기재고</th><th>전체 재고</th><th>비율</th><th>시각화</th></tr></thead>
    <tbody>${rows.map(r => `<tr>
      <td>${r.name}${WAREHOUSE.includes(r.name) ? '<span class="tag-warehouse">창고</span>' : ''}</td>
      <td><span class="badge badge-red">${fmt(r.old)}</span></td>
      <td>${fmt(r.total)}</td>
      <td>${pct(r.old, r.total)}</td>
      <td style="width:140px">
        <div class="old-bar-bg">
          <div class="old-bar-fill" style="width:${Math.min(r.old/r.total*100,100)}%"></div>
        </div>
      </td>
    </tr>`).join('')}</tbody>
  </table></div>`;
}

// ─── Location detail ──────────────────────────────────────────────────────────
async function renderLocation(name) {
  const isWh = WAREHOUSE.includes(name);
  if (!allLocations.find(l => l.name === name)) {
    document.getElementById('content').innerHTML = '<div class="empty">위치를 찾을 수 없습니다.</div>';
    return;
  }

  // Fetch in parallel; store-specific data only for non-warehouses
  const fetches = [fetchItems(name)];
  if (!isWh) {
    fetches.push(fetchStoreSales(name));
    fetches.push(fetchArrivalMap(name));
    fetches.push(fetchYesterdayCatSales(name));
    fetches.push(fetchMonthlyCatSales(name));
  }
  const [items, sales = [], arrivalMap = {}, yestSales = {}, monthlyCatSales = {}] = await Promise.all(fetches);

  const cats    = buildCategoryStats(items, arrivalMap);
  const buckets = calcAgeBuckets(items, arrivalMap);
  const monthRev  = (sales || []).reduce((s, i) => s + (i.price || 0), 0);
  const oldCount  = items.filter(i => getArrivalAge(i, arrivalMap) > 90).length;
  const yestTotal = Object.values(yestSales).reduce((s, v) => s + v, 0);

  document.getElementById('content').innerHTML = `
    <div class="page-header">
      <div>
        <div class="page-title">${name}${isWh ? '<span class="tag-warehouse" style="font-size:14px;padding:3px 10px">창고</span>' : ''}</div>
        <div class="page-sub">${isWh ? '보관 재고 현황' : '매장 재고 · 매출 현황'}</div>
      </div>
      <button class="btn-refresh" onclick="route()">${iconRefresh()} 새로고침</button>
    </div>

    <div class="cards-row ${isWh ? 'cards-row-2' : ''}">
      <div class="stat-card stat-card-peach">
        <div class="stat-label">현재 재고</div>
        <div class="stat-value">${fmt(items.length)}</div>
        <div class="stat-sub">${cats.length}개 카테고리</div>
      </div>
      ${!isWh ? `
      <div class="stat-card stat-card-teal">
        <div class="stat-label">이달 매출</div>
        <div class="stat-value">${fmtMoney(monthRev)}</div>
        <div class="stat-sub">${thisMonth()} · ${fmt((sales||[]).length)}건</div>
      </div>
      <div class="stat-card stat-card-ochre">
        <div class="stat-label">어제 판매</div>
        <div class="stat-value">${fmt(yestTotal)}</div>
        <div class="stat-sub">건 · ${yesterday()}</div>
      </div>` : ''}
      <div class="stat-card stat-card-pink">
        <div class="stat-label">장기재고 90일+</div>
        <div class="stat-value">${fmt(oldCount)}</div>
        <div class="stat-sub">${items.length ? pct(oldCount, items.length) : '0%'} (매장 도착 기준)</div>
      </div>
    </div>

    ${!isWh ? renderDeadStockAlert(cats) : ''}

    <div class="section-card">
      <h3>카테고리별 재고 현황 <span style="font-size:11px;font-weight:400;color:var(--muted)">(클릭하면 연령 분포 확인)</span></h3>
      <div class="cat-grid" id="cat-grid">
        ${renderCatGrid(cats, yestSales, monthlyCatSales)}
      </div>
    </div>

    <div class="section-card">
      <h3>전체 재고 연령 분포 <span style="font-size:11px;font-weight:400;color:var(--muted)">매장 도착일 기준</span></h3>
      <div class="chart-wrap"><canvas id="chart-age"></canvas></div>
    </div>
  `;

  drawAgeChart(buckets);
  document.getElementById('cat-grid').addEventListener('click', onCatClick);
}

function renderCatGrid(cats, yestSales = {}, monthlyCatSales = {}) {
  if (!cats.length) return '<div class="empty">재고 없음</div>';
  const total = cats.reduce((s, c) => s + c.total, 0);

  return cats.map((c, i) => {
    const sold30 = monthlyCatSales[c.name] || 0;
    const strDenom = sold30 + c.total;
    const str = strDenom > 0 ? Math.round(sold30 / strDenom * 100) : 0;
    const strColor = str >= 50 ? '#22c55e' : str >= 20 ? '#f59e0b' : '#ef4444';
    const strLabel = str >= 50 ? '빠름' : str >= 20 ? '보통' : '느림';

    const ySold = yestSales[c.name] || 0;
    const yestHtml = ySold > 0
      ? `<div class="cat-yest-badge">어제 ${ySold}건</div>`
      : `<div class="cat-yest-zero">어제 0건</div>`;

    return `
      <div class="cat-card" data-cat-idx="${i}">
        <div class="cat-card-name" title="${c.name}">${c.name}</div>
        <div class="cat-card-count">${fmt(c.total)}</div>
        <div class="cat-age-bar">
          ${mkAgeSeg(c.d30, c.total, AGE_COLORS['0-30일'])}
          ${mkAgeSeg(c.d60, c.total, AGE_COLORS['31-60일'])}
          ${mkAgeSeg(c.d90, c.total, AGE_COLORS['61-90일'])}
          ${mkAgeSeg(c.old, c.total, AGE_COLORS['90일+'])}
        </div>
        <div class="cat-str">
          <span style="color:${strColor};font-weight:600">${str}%</span>
          <span style="color:var(--muted-soft)"> 소진 · ${strLabel}</span>
        </div>
        ${yestHtml}
      </div>
    `;
  }).join('');
}

function mkAgeSeg(n, total, color) {
  if (!n) return '';
  const w = Math.max(Math.round(n / total * 100), 2);
  return `<div class="cat-age-seg" style="width:${w}%;background:${color}" title="${n}개"></div>`;
}

function onCatClick(e) {
  const card = e.target.closest('.cat-card');
  if (!card) return;

  const idx  = parseInt(card.dataset.catIdx);
  const grid = document.getElementById('cat-grid');

  grid.querySelectorAll('.cat-expand').forEach(el => el.remove());
  grid.querySelectorAll('.cat-card').forEach(el => el.classList.remove('expanded'));

  if (expandedCat === idx) { expandedCat = null; return; }
  expandedCat = idx;
  card.classList.add('expanded');

  const cats = window.__cats || [];
  const cat  = cats[idx];
  if (!cat) return;

  const panel = document.createElement('div');
  panel.className = 'cat-expand show';
  panel.innerHTML = `
    <div class="cat-expand-title">${cat.name} — 매장 도착일 기준 연령 분포</div>
    <div class="age-breakdown">
      ${ageBox('0–30일',  cat.d30,  '#22c55e', '#d1fae5', 'd30')}
      ${ageBox('31–60일', cat.d60,  '#f59e0b', '#fef3c7', 'd60')}
      ${ageBox('61–90일', cat.d90,  '#f97316', '#ffedd5', 'd90')}
      ${ageBox('90일+',   cat.old,  '#ef4444', '#fee2e2', 'old')}
    </div>
    <div class="barcode-list-wrap"></div>
  `;

  panel.querySelector('.age-breakdown').addEventListener('click', e => {
    const box = e.target.closest('[data-bucket]');
    if (!box) return;
    const bucket = box.dataset.bucket;
    const wrap = panel.querySelector('.barcode-list-wrap');
    const barcodes = (cat.barcodes || {})[bucket] || [];
    const isActive = wrap.dataset.activeBucket === bucket;
    panel.querySelectorAll('[data-bucket]').forEach(b => b.classList.remove('active'));
    if (isActive) {
      wrap.innerHTML = '';
      wrap.dataset.activeBucket = '';
    } else {
      box.classList.add('active');
      wrap.dataset.activeBucket = bucket;
      wrap.innerHTML = renderBarcodeList(barcodes);
    }
  });

  card.after(panel);
}

function ageBox(label, val, color, bg, bucket) {
  const clickable = val > 0 && bucket;
  return `<div class="age-bucket${clickable ? ' age-bucket-clickable' : ''}" style="background:${bg}"${clickable ? ` data-bucket="${bucket}"` : ''}>
    <div class="bk-label">${label}</div>
    <div class="bk-val" style="color:${color}">${fmt(val)}</div>
    ${clickable ? `<div class="bk-hint" style="color:${color}">목록 보기 ▼</div>` : ''}
  </div>`;
}

function renderBarcodeList(barcodes) {
  if (!barcodes.length) return '<div class="empty" style="padding:10px 0">바코드 없음</div>';
  return `<div class="barcode-list">${barcodes.map(b => `<span class="barcode-chip">${b}</span>`).join('')}</div>`;
}

// ─── Dead stock alert ─────────────────────────────────────────────────────────
function renderDeadStockAlert(cats) {
  const alerts = cats
    .filter(c => c.old > 0)
    .sort((a, b) => (b.old / b.total) - (a.old / a.total));

  if (!alerts.length) {
    return `
    <div class="section-card" style="border-color:var(--success)">
      <h3>장기재고 처리 권장</h3>
      <div class="empty" style="color:var(--success);padding:12px 0">90일 이상 장기재고 없음</div>
    </div>`;
  }

  const rows = alerts.map(c => {
    const ratio = Math.round(c.old / c.total * 100);
    const urgency = ratio >= 50 ? { color: '#ef4444', bg: '#fee2e2', label: '긴급' }
                  : ratio >= 25 ? { color: '#f97316', bg: '#ffedd5', label: '주의' }
                  :               { color: '#f59e0b', bg: '#fef3c7', label: '모니터링' };
    return `
      <div class="dead-stock-row">
        <div class="ds-name">${c.name}</div>
        <div class="ds-bar-wrap">
          <div class="ds-bar-bg">
            <div class="ds-bar-fill" style="width:${ratio}%;background:${urgency.color}"></div>
          </div>
          <span class="ds-pct" style="color:${urgency.color}">${ratio}%</span>
        </div>
        <div class="ds-detail">${fmt(c.old)}개 / 전체 ${fmt(c.total)}개</div>
        <span class="ds-badge" style="background:${urgency.bg};color:${urgency.color}">${urgency.label}</span>
      </div>`;
  }).join('');

  return `
  <div class="section-card" style="border-color:var(--error)">
    <h3>장기재고 처리 권장 <span style="font-size:11px;font-weight:400;color:var(--muted)">90일 이상 · 매장 도착일 기준 · 비율 순</span></h3>
    <div class="dead-stock-list">${rows}</div>
  </div>`;
}

// ─── Charts ───────────────────────────────────────────────────────────────────
function drawStockChart(counts) {
  const ctx = document.getElementById('chart-stock');
  if (!ctx) return;
  const sorted = [...counts].sort((a, b) => b.count - a.count);
  activeCharts.stock = new Chart(ctx, {
    type: 'bar',
    data: {
      labels:   sorted.map(c => c.name),
      datasets: [{ data: sorted.map(c => c.count),
        backgroundColor: sorted.map(c => WAREHOUSE.includes(c.name) ? '#b8a4ed' : '#1a3a3a'),
        borderRadius: 5 }]
    },
    options: {
      indexAxis: 'y',
      plugins: { legend: { display: false } },
      scales: {
        x: { grid: { color: '#ebe6d6' }, ticks: { font: { size: 11 } } },
        y: { grid: { display: false }, ticks: { font: { size: 12 } } },
      }
    }
  });
}

function drawSalesChart(stores, sales) {
  const ctx = document.getElementById('chart-sales');
  if (!ctx) return;
  const data = stores
    .map(n => ({ name: n, rev: sales[n]?.revenue || 0 }))
    .sort((a, b) => b.rev - a.rev);

  activeCharts.sales = new Chart(ctx, {
    type: 'bar',
    data: {
      labels:   data.map(d => d.name),
      datasets: [{ data: data.map(d => d.rev), backgroundColor: '#ffb084', borderRadius: 5 }]
    },
    options: {
      plugins: { legend: { display: false } },
      scales: {
        x: { grid: { display: false }, ticks: { font: { size: 12 } } },
        y: { grid: { color: '#ebe6d6' }, ticks: { font: { size: 11 }, callback: v => fmtShort(v) } }
      }
    }
  });
}

function drawAgeChart(buckets) {
  const ctx = document.getElementById('chart-age');
  if (!ctx) return;
  const labels = Object.keys(AGE_COLORS);
  activeCharts.age = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: ['재고 연령'],
      datasets: labels.map(k => ({
        label: k, data: [buckets[k] || 0],
        backgroundColor: AGE_COLORS[k], borderRadius: 4
      }))
    },
    options: {
      indexAxis: 'y',
      plugins: { legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 11 } } },
      scales: {
        x: { stacked: true, grid: { color: '#ebe6d6' }, ticks: { font: { size: 11 } } },
        y: { stacked: true, grid: { display: false }, ticks: { display: false } }
      }
    }
  });
}

// ─── Data ─────────────────────────────────────────────────────────────────────
async function fetchLocations() {
  const { data } = await sb.from('locations').select('id,name,is_active').eq('is_active', true).order('created_at');
  return (data || []).filter(l => !EXCLUDED.includes(l.name));
}

async function fetchCounts(names) {
  return Promise.all(names.map(async name => {
    const { count } = await sb.from('inventory_items').select('*', { count: 'exact', head: true })
      .eq('location', name).neq('status', 'sold');
    return { name, count: count || 0 };
  }));
}

async function fetchOldCounts(names, days) {
  const cutoff = new Date(); cutoff.setDate(cutoff.getDate() - days);
  return Promise.all(names.map(async name => {
    const { count } = await sb.from('inventory_items').select('*', { count: 'exact', head: true })
      .eq('location', name).neq('status', 'sold').lt('created_at', cutoff.toISOString());
    return { name, count: count || 0 };
  }));
}

async function fetchMonthlySales(locationNames) {
  const storeNames = locationNames.filter(n => !WAREHOUSE.includes(n)).map(n => SOLD_PFX + n);
  if (!storeNames.length) return {};
  const { data } = await sb.from('sold_items').select('store,price')
    .in('store', storeNames).gte('sold_date', monthStart());
  const r = {};
  (data || []).forEach(item => {
    const loc = item.store.replace(SOLD_PFX, '');
    if (!r[loc]) r[loc] = { revenue: 0, count: 0 };
    r[loc].revenue += item.price || 0;
    r[loc].count++;
  });
  return r;
}

async function fetchItems(locationName) {
  const all = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from('inventory_items')
      .select('barcode,category,created_at').eq('location', locationName).neq('status', 'sold').range(from, from + 999);
    if (error || !data?.length) break;
    all.push(...data);
    if (data.length < 1000) break;
  }
  return all;
}

async function fetchStoreSales(locationName) {
  const { data } = await sb.from('sold_items').select('sold_date,price')
    .eq('store', SOLD_PFX + locationName).gte('sold_date', monthStart())
    .order('sold_date', { ascending: false }).limit(1000);
  return data || [];
}

// Returns barcode → session_date (latest arrival at this location via move sessions)
async function fetchArrivalMap(locationName) {
  try {
    // Step 1: get all approved move_sessions where to_location = this store
    const { data: sessions } = await sb.from('move_sessions')
      .select('id,session_date')
      .eq('to_location', locationName)
      .eq('status', 'approved');

    if (!sessions?.length) return {};

    const sessionDateMap = Object.fromEntries(sessions.map(s => [s.id, s.session_date]));
    const sessionIds = sessions.map(s => s.id);
    const map = {}; // barcode → latest session_date

    // Step 2: fetch session_items for those sessions in chunks
    const chunkSize = 50;
    for (let ci = 0; ci < sessionIds.length; ci += chunkSize) {
      const chunk = sessionIds.slice(ci, ci + chunkSize);
      let from = 0;
      while (true) {
        const { data, error } = await sb.from('session_items')
          .select('barcode,session_id')
          .in('session_id', chunk)
          .range(from, from + 999);
        if (error || !data?.length) break;
        data.forEach(row => {
          const date = sessionDateMap[row.session_id];
          if (date && (!map[row.barcode] || date > map[row.barcode])) {
            map[row.barcode] = date;
          }
        });
        if (data.length < 1000) break;
        from += 1000;
      }
    }
    return map;
  } catch {
    return {};
  }
}

// Returns { categoryName: count } for last 30 days sales at this store
async function fetchMonthlyCatSales(locationName) {
  try {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 30);
    const cutoffStr = cutoff.toISOString().slice(0, 10);

    const { data: sold } = await sb.from('sold_items')
      .select('barcode')
      .eq('store', SOLD_PFX + locationName)
      .gte('sold_date', cutoffStr);

    if (!sold?.length) return {};

    const barcodes = [...new Set(sold.map(s => s.barcode))];
    const catCounts = {};
    for (let i = 0; i < barcodes.length; i += 200) {
      const chunk = barcodes.slice(i, i + 200);
      const { data: items } = await sb.from('inventory_items')
        .select('barcode,category')
        .in('barcode', chunk);
      (items || []).forEach(item => {
        const cat = normalizeCatName(item.category);
        catCounts[cat] = (catCounts[cat] || 0) + 1;
      });
    }
    return catCounts;
  } catch {
    return {};
  }
}

// Returns { categoryName: count } for yesterday's sales at this store
async function fetchYesterdayCatSales(locationName) {
  try {
    const ymd = yesterdayStr();
    const { data: sold } = await sb.from('sold_items')
      .select('barcode')
      .eq('store', SOLD_PFX + locationName)
      .eq('sold_date', ymd);

    if (!sold?.length) return {};

    const barcodes = [...new Set(sold.map(s => s.barcode))];
    const catCounts = {};

    // Fetch categories in chunks
    for (let i = 0; i < barcodes.length; i += 200) {
      const chunk = barcodes.slice(i, i + 200);
      const { data: items } = await sb.from('inventory_items')
        .select('barcode,category')
        .in('barcode', chunk);
      (items || []).forEach(item => {
        const cat = normalizeCatName(item.category);
        catCounts[cat] = (catCounts[cat] || 0) + 1;
      });
    }
    return catCounts;
  } catch {
    return {};
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
// Pure-alpha category names (e.g. "pk", "Pk", "c") → uppercase to merge duplicates
function normalizeCatName(name) {
  if (!name) return '미분류';
  return /^[A-Za-z]+$/.test(name) ? name.toUpperCase() : name;
}

// How many days has this item been at this location?
function getArrivalAge(item, arrivalMap) {
  const arrivedAt = arrivalMap[item.barcode] || item.created_at;
  return Math.floor((Date.now() - new Date(arrivedAt)) / 86400000);
}

function buildCategoryStats(items, arrivalMap = {}) {
  const map = {};
  items.forEach(item => {
    const k   = normalizeCatName(item.category);
    const age = getArrivalAge(item, arrivalMap);
    if (!map[k]) map[k] = { total: 0, d30: 0, d60: 0, d90: 0, old: 0, barcodes: { d30: [], d60: [], d90: [], old: [] } };
    map[k].total++;
    if      (age <= 30) { map[k].d30++; map[k].barcodes.d30.push(item.barcode); }
    else if (age <= 60) { map[k].d60++; map[k].barcodes.d60.push(item.barcode); }
    else if (age <= 90) { map[k].d90++; map[k].barcodes.d90.push(item.barcode); }
    else                { map[k].old++;  map[k].barcodes.old.push(item.barcode); }
  });
  const cats = Object.entries(map)
    .sort((a, b) => b[1].total - a[1].total)
    .map(([name, s]) => ({ name, ...s }));
  window.__cats = cats;
  return cats;
}

function calcAgeBuckets(items, arrivalMap = {}) {
  const b = { '0-30일': 0, '31-60일': 0, '61-90일': 0, '90일+': 0 };
  items.forEach(i => {
    const d = getArrivalAge(i, arrivalMap);
    if      (d <= 30) b['0-30일']++;
    else if (d <= 60) b['31-60일']++;
    else if (d <= 90) b['61-90일']++;
    else              b['90일+']++;
  });
  return b;
}

function monthStart() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-01`;
}
function yesterdayStr() {
  const d = new Date(); d.setDate(d.getDate() - 1);
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}
function yesterday() {
  const d = new Date(); d.setDate(d.getDate() - 1);
  return `${d.getMonth()+1}월 ${d.getDate()}일`;
}
function thisMonth() {
  const d = new Date();
  return `${d.getFullYear()}년 ${d.getMonth()+1}월`;
}
function fmt(n)       { return (n||0).toLocaleString('ko-KR'); }
function fmtMoney(n)  {
  if (!n) return '₩0';
  if (n >= 100000000) return `₩${(n/100000000).toFixed(1)}억`;
  if (n >= 10000)     return `₩${Math.round(n/10000)}만`;
  return `₩${fmt(n)}`;
}
function fmtShort(n) {
  if (n >= 100000000) return `${(n/100000000).toFixed(0)}억`;
  if (n >= 10000)     return `${Math.round(n/10000)}만`;
  return fmt(n);
}
function pct(a, b)    { return b ? `${Math.round(a/b*100)}%` : '0%'; }
function enc(s)       { return encodeURIComponent(s); }

function destroyCharts() { Object.values(activeCharts).forEach(c => c.destroy()); activeCharts = {}; }
function showLoading(on) { document.getElementById('loading').style.display = on ? 'flex' : 'none'; }
function updateFooter()  {
  const t = new Date().toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' });
  const el = document.getElementById('footer-time');
  if (el) el.textContent = `마지막 업데이트\n${t}`;
}

// ─── Icons ────────────────────────────────────────────────────────────────────
function iconHome()    { return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>`; }
function iconDot()     { return `<span class="nav-dot"></span>`; }
function iconRefresh() { return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>`; }

// ─── Start ────────────────────────────────────────────────────────────────────
init();
