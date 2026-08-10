// ── 바코드 정규화 ─────────────────────────────────────────────────────────────
function normalizeBarcode(input) {
  const JAMO_TO_ENG = {
    'ㄱ':'r','ㄲ':'R','ㄴ':'s','ㄷ':'e','ㄸ':'E','ㄹ':'f','ㅁ':'a','ㅂ':'q','ㅃ':'Q',
    'ㅅ':'t','ㅆ':'T','ㅇ':'','ㅈ':'w','ㅉ':'W','ㅊ':'c','ㅋ':'z','ㅌ':'x','ㅍ':'v','ㅎ':'g',
    'ㅏ':'k','ㅐ':'o','ㅑ':'i','ㅒ':'O','ㅓ':'j','ㅔ':'p','ㅕ':'u','ㅖ':'P',
    'ㅗ':'h','ㅘ':'hk','ㅙ':'ho','ㅚ':'hl','ㅛ':'y',
    'ㅜ':'n','ㅝ':'nj','ㅞ':'np','ㅟ':'nl','ㅠ':'b',
    'ㅡ':'m','ㅢ':'ml','ㅣ':'l',
  };
  const INITIALS = ['ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ','ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'];
  const VOWELS   = ['ㅏ','ㅐ','ㅑ','ㅒ','ㅓ','ㅔ','ㅕ','ㅖ','ㅗ','ㅘ','ㅙ','ㅚ','ㅛ','ㅜ','ㅝ','ㅞ','ㅟ','ㅠ','ㅡ','ㅢ','ㅣ'];
  const FINALS   = ['','ㄱ','ㄲ','ㄳ','ㄴ','ㄵ','ㄶ','ㄷ','ㄹ','ㄺ','ㄻ','ㄼ','ㄽ','ㄾ','ㄿ','ㅀ','ㅁ','ㅂ','ㅄ','ㅅ','ㅆ','ㅇ','ㅈ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'];
  let result = '';
  for (const ch of input) {
    const code = ch.charCodeAt(0);
    if (code >= 0xAC00 && code <= 0xD7A3) {
      const offset = code - 0xAC00;
      const iIdx = Math.floor(offset / (21 * 28));
      const vIdx = Math.floor((offset % (21 * 28)) / 28);
      const fIdx = offset % 28;
      result += JAMO_TO_ENG[INITIALS[iIdx]] ?? '';
      result += JAMO_TO_ENG[VOWELS[vIdx]]  ?? '';
      if (fIdx > 0) result += JAMO_TO_ENG[FINALS[fIdx]] ?? '';
    } else if (code >= 0x3130 && code <= 0x318F) {
      result += JAMO_TO_ENG[ch] ?? ch;
    } else {
      result += ch;
    }
  }
  return result.toUpperCase().trim();
}

// ── 탭 전환 ───────────────────────────────────────────────────────────────────
const TABS = ['scan', 'manual'];
let currentTab = 'scan';

document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    currentTab = btn.dataset.tab;
    TABS.forEach(t => {
      document.getElementById('panel-' + t).classList.toggle('active', t === currentTab);
    });
    document.querySelectorAll('.tab-btn').forEach(b =>
      b.classList.toggle('active', b.dataset.tab === currentTab)
    );
    document.getElementById('scan-area').style.display = 'block';
    if (currentTab === 'scan')   document.getElementById('barcode-input').focus();
    if (currentTab === 'manual') document.getElementById('manual-barcode').focus();

  });
});

// ── 스캔 목록 ─────────────────────────────────────────────────────────────────
const scanned = [], scannedSet = new Set();

function addBarcode(bc) {
  if (!bc || scannedSet.has(bc)) return;
  scanned.push(bc); scannedSet.add(bc); renderScanList();
}
function removeBarcode(idx) {
  const bc = scanned.splice(idx, 1)[0]; scannedSet.delete(bc); renderScanList();
}
function clearAll() {
  scanned.length = 0; scannedSet.clear(); renderScanList();
  document.getElementById('result').innerHTML = '';
}
function renderScanList() {
  const list  = document.getElementById('scan-list');
  const empty = document.getElementById('scan-empty');
  const count = scanned.length;
  document.getElementById('count').textContent = count;
  document.getElementById('search-btn').disabled = count === 0;
  document.getElementById('scan-box').classList.toggle('active', count > 0);
  if (count === 0) { list.innerHTML = ''; empty.style.display = 'block'; return; }
  empty.style.display = 'none';
  list.innerHTML = scanned.map((bc, i) =>
    `<div class="scan-row">
      <span class="scan-row-num">${i + 1}</span>
      <span class="scan-row-bc">${escapeHtml(bc)}</span>
      <button class="scan-row-del" data-idx="${i}">×</button>
    </div>`
  ).join('');
  list.querySelectorAll('.scan-row-del').forEach(b =>
    b.addEventListener('click', () => removeBarcode(parseInt(b.dataset.idx, 10)))
  );
}

const bi = document.getElementById('barcode-input');
let scanTimer = null;
bi.addEventListener('keydown', e => {
  if (e.key === 'Enter') {
    e.preventDefault(); clearTimeout(scanTimer);
    const v = normalizeBarcode(bi.value); bi.value = '';
    if (v) addBarcode(v);
  }
});
bi.addEventListener('input', () => {
  clearTimeout(scanTimer);
  scanTimer = setTimeout(() => {
    const v = normalizeBarcode(bi.value); bi.value = ''; if (v) addBarcode(v);
  }, 500);
});
document.getElementById('manual-barcode').addEventListener('keydown', e => {
  if (e.key === 'Enter') {
    e.preventDefault();
    const v = normalizeBarcode(e.target.value); e.target.value = ''; if (v) addBarcode(v);
  }
});
document.getElementById('paste-btn').addEventListener('click', () => {
  const ta = document.getElementById('paste-area');
  ta.value.split(/[\n,\s]+/).map(s => normalizeBarcode(s)).filter(Boolean).forEach(addBarcode);
  ta.value = '';
});
document.getElementById('clear-btn').addEventListener('click', clearAll);

// ── Supabase 조회 ─────────────────────────────────────────────────────────────
async function fetchItemData(bc) {
  const [invRes, moveRes, priceRes, soldRes] = await Promise.all([
    sb.from('inventory_items')
      .select('*, inventory_hangers(category, submitted_by, inventory_sessions(location, barcode_prefix, session_date, created_by))')
      .eq('barcode', bc),
    sb.from('session_items')
      .select('*, move_sessions(to_location, session_date, from_location, created_by)')
      .eq('barcode', bc)
      .eq('is_submitted', true)
      .order('scanned_at', { ascending: true }),
    sb.from('price_changes')
      .select('*')
      .eq('barcode', bc)
      .order('changed_at', { ascending: true }),
    sb.from('sold_items')
      .select('*')
      .eq('barcode', bc),
  ]);

  const invItem = (invRes.data || [])[0] || null;
  const moves   = moveRes.data || [];
  const prices  = priceRes.data || [];
  const sold    = (soldRes.data || [])[0] || null;

  if (!invItem) return { items: [], timeline: [], q: bc };

  const hanger  = invItem.inventory_hangers || {};
  const session = hanger.inventory_sessions || {};
  const category = hanger.category || invItem.category || '';
  const location = session.location || invItem.location || '';

  const item = {
    barcode:   invItem.barcode,
    price:     invItem.price,
    brand:     invItem.brand,
    photo_url: invItem.photo_url || null,
    category,
    location,
    status:    sold ? 'sold' : 'active',
  };

  // 타임라인 조립
  const timeline = [];
  timeline.push({
    type:     'ingest',
    ts:       session.session_date || invItem.created_at,
    price:    invItem.price,
    by:       hanger.submitted_by || session.created_by,
  });
  moves.forEach(m => {
    const ms = m.move_sessions || {};
    timeline.push({
      type:          'move',
      ts:            ms.session_date || m.created_at,
      from_location: ms.from_location || '',
      to_location:   ms.to_location || '',
      by:            m.scanned_by || ms.created_by || '',
    });
  });
  prices.forEach(p => {
    timeline.push({
      type:      'price',
      ts:        p.changed_at,
      old_price: p.old_price,
      new_price: p.new_price,
      by:        p.changed_by,
    });
  });
  if (sold) {
    timeline.push({
      type:  'sold',
      ts:    sold.sold_date,
      store: sold.store,
      price: sold.price,
    });
  }
  timeline.sort((a, b) => (a.ts || '') < (b.ts || '') ? -1 : 1);

  return { items: [item], timeline, detail_item: item, q: bc };
}

// ── 조회 실행 ─────────────────────────────────────────────────────────────────
document.getElementById('search-btn').addEventListener('click', () => searchBarcodes(scanned));

async function searchBarcodes(barcodes) {
  if (barcodes.length === 0) return;
  const resultEl = document.getElementById('result');
  resultEl.innerHTML = '<div class="empty" style="color:#60a5fa">⏳ 조회 중...</div>';
  clearError();
  try {
    if (barcodes.length === 1) {
      const data = await fetchItemData(barcodes[0]);
      resultEl.innerHTML = renderSingle(data);
    } else {
      const results = await Promise.all(barcodes.map(bc => fetchItemData(bc).catch(() => null)));
      renderBulk(barcodes, results);
    }
  } catch (e) {
    showError('조회 실패: ' + e.message);
    resultEl.innerHTML = '';
  }
}

// ── 렌더 ─────────────────────────────────────────────────────────────────────
const STATUS_LABEL = { active: '보유중', sold: '판매됨', moved: '이동중' };

function renderSingle(data) {
  let html = '';
  if (data.timeline && data.timeline.length > 0) {
    const det = data.detail_item || {};
    html += `<div class="tl-card">
      <div class="tl-card-title">📋 ${escapeHtml(det.barcode || (data.q || '').toUpperCase())} 전체 이력</div>`;
    html += data.timeline.map(ev => {
      if (ev.type === 'ingest') return `
        <div class="tl-item"><span class="tl-icon">📦</span>
          <div class="tl-body">
            <div class="tl-main">입고</div>
            <div class="tl-sub">₩${ev.price ? ev.price.toLocaleString() : '—'}${ev.by ? ' · ' + escapeHtml(ev.by) : ''}</div>
          </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
        </div>`;
      if (ev.type === 'move') return `
        <div class="tl-item"><span class="tl-icon">🚚</span>
          <div class="tl-body">
            <div class="tl-main">이동 — ${escapeHtml(ev.from_location)} → ${escapeHtml(ev.to_location)}</div>
            <div class="tl-sub">${ev.by ? escapeHtml(ev.by) + ' 스캔' : ''}</div>
          </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
        </div>`;
      if (ev.type === 'price') return `
        <div class="tl-item"><span class="tl-icon">💰</span>
          <div class="tl-body">
            <div class="tl-main">가격수정 — ₩${ev.old_price ? ev.old_price.toLocaleString() : '?'} → ₩${ev.new_price ? ev.new_price.toLocaleString() : '?'}</div>
            <div class="tl-sub">${ev.by ? escapeHtml(ev.by) : ''}</div>
          </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
        </div>`;
      if (ev.type === 'sold') return `
        <div class="tl-item"><span class="tl-icon">🛍</span>
          <div class="tl-body">
            <div class="tl-main" style="color:#4ade80">판매 완료 — ${escapeHtml(ev.store || '—')}</div>
            <div class="tl-sub">₩${ev.price ? ev.price.toLocaleString() : '—'}</div>
          </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
        </div>`;
      return '';
    }).join('');
    html += '</div>';
  }
  const items = data.items || [];
  if (items.length === 0) {
    html += `<div class="empty">「${escapeHtml(data.q || '')}」 검색 결과 없음</div>`;
  } else {
    html += `<div class="muted text-sm mb8">${items.length}건</div>` + items.map(renderItemCard).join('');
  }
  return html;
}

function renderBulk(barcodes, results) {
  const found    = results.filter(r => r && (r.items || []).length > 0).length;
  const notFound = barcodes.length - found;
  const resultEl = document.getElementById('result');

  let html = `<div class="muted text-sm mb8">총 ${barcodes.length}개 조회 — 확인 ${found}건${notFound > 0 ? ` / 미확인 ${notFound}건` : ''}</div>`;
  barcodes.forEach((bc, i) => {
    const data  = results[i];
    const items = data ? (data.items || []) : [];
    const item  = items[0] || null;
    if (!item) {
      html += `<div class="item-card" style="border-color:#374151; opacity:0.5">
        <div class="item-bc" style="color:#64748b">${escapeHtml(bc)}</div>
        <div class="text-sm muted" style="margin-top:4px">조회 결과 없음</div>
      </div>`;
    } else {
      html += renderItemCard(item, true);
    }
  });

  resultEl.innerHTML = html;
  resultEl.querySelectorAll('.item-card[data-barcode]').forEach(card => {
    card.addEventListener('click', () => toggleTimeline(card));
  });
}

async function toggleTimeline(card) {
  const bc      = card.dataset.barcode;
  const chevron = card.querySelector('.card-chevron');
  let   tl      = card.nextElementSibling;
  const isOpen  = tl && tl.classList.contains('tl-accordion');

  if (isOpen) {
    tl.style.maxHeight = '0'; tl.style.opacity = '0';
    setTimeout(() => tl.remove(), 250);
    chevron.textContent = '›'; card.style.borderBottomColor = '';
    return;
  }

  chevron.textContent = '⏳'; card.style.borderBottomColor = '#3b82f6';
  try {
    const data     = await fetchItemData(bc);
    const timeline = data.timeline || [];
    const div      = document.createElement('div');
    div.className  = 'tl-accordion';
    div.style.cssText = 'max-height:0; opacity:0; overflow:hidden; transition:max-height .3s ease, opacity .25s ease;';

    if (timeline.length === 0) {
      div.innerHTML = `<div class="tl-empty">이력 없음</div>`;
    } else {
      div.innerHTML = timeline.map(ev => {
        if (ev.type === 'ingest') return `
          <div class="tl-item"><span class="tl-icon">📦</span>
            <div class="tl-body">
              <div class="tl-main">입고</div>
              <div class="tl-sub">₩${ev.price ? ev.price.toLocaleString() : '—'}${ev.by ? ' · ' + escapeHtml(ev.by) : ''}</div>
            </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
          </div>`;
        if (ev.type === 'move') return `
          <div class="tl-item"><span class="tl-icon">🚚</span>
            <div class="tl-body">
              <div class="tl-main">이동 — ${escapeHtml(ev.from_location)} → ${escapeHtml(ev.to_location)}</div>
              <div class="tl-sub">${ev.by ? escapeHtml(ev.by) + ' 스캔' : ''}</div>
            </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
          </div>`;
        if (ev.type === 'price') return `
          <div class="tl-item"><span class="tl-icon">💰</span>
            <div class="tl-body">
              <div class="tl-main">가격수정 — ₩${ev.old_price ? ev.old_price.toLocaleString() : '?'} → ₩${ev.new_price ? ev.new_price.toLocaleString() : '?'}</div>
              <div class="tl-sub">${ev.by ? escapeHtml(ev.by) : ''}</div>
            </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
          </div>`;
        if (ev.type === 'sold') return `
          <div class="tl-item"><span class="tl-icon">🛍</span>
            <div class="tl-body">
              <div class="tl-main" style="color:#4ade80">판매 완료 — ${escapeHtml(ev.store || '—')}</div>
              <div class="tl-sub">₩${ev.price ? ev.price.toLocaleString() : '—'}</div>
            </div><span class="tl-date">${(ev.ts || '').slice(0, 10)}</span>
          </div>`;
        return '';
      }).join('');
    }

    card.insertAdjacentElement('afterend', div);
    requestAnimationFrame(() => { div.style.maxHeight = div.scrollHeight + 'px'; div.style.opacity = '1'; });
    chevron.textContent = '▾';
  } catch (e) {
    chevron.textContent = '›'; card.style.borderBottomColor = '';
    showError('이력 조회 실패: ' + e.message);
  }
}

function renderItemCard(item, clickable = false) {
  const bc   = item.barcode || '';
  const attr = clickable ? `data-barcode="${escapeHtml(bc)}" style="cursor:pointer"` : '';
  return `<div class="item-card" ${attr}>
    <div class="flex" style="align-items:center; margin-bottom:6px">
      <span class="item-bc">${escapeHtml(bc || '바코드없음')}</span>
      <span class="item-status status-${escapeHtml(item.status || 'active')}">
        ${STATUS_LABEL[item.status] || item.status || '보유중'}
      </span>
      ${clickable ? '<span class="card-chevron" style="margin-left:auto; color:#475569; font-size:18px">›</span>' : ''}
    </div>
    <div class="flex" style="gap:12px; align-items:flex-start">
      ${item.photo_url ? `<img src="${escapeHtml(item.photo_url)}" style="width:72px; height:72px; object-fit:cover; border-radius:8px; flex-shrink:0; cursor:zoom-in" alt="사진" onclick="event.stopPropagation(); viewPhoto('${escapeHtml(item.photo_url)}')">` : ''}
      <div>
        <div style="font-size:15px; font-weight:700; color:var(--fg-primary)">
          ₩${item.price ? item.price.toLocaleString() : '—'}
          ${item.brand ? `<span style="font-size:13px; color:var(--fg-secondary); font-weight:400"> · ${escapeHtml(item.brand)}</span>` : ''}
        </div>
        <div class="text-sm muted" style="margin-top:3px">
          ${escapeHtml(item.category || '—')}${item.location ? ' · ' + escapeHtml(item.location) : ''}
        </div>
      </div>
    </div>
  </div>`;
}

setTimeout(() => bi.focus(), 200);
