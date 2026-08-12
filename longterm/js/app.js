// ── helpers ──────────────────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function fmtDate(str) {
  if (!str) return '-';
  const d = new Date(str);
  return `${d.getFullYear()}.${String(d.getMonth()+1).padStart(2,'0')}.${String(d.getDate()).padStart(2,'0')}`;
}

function daysDiff(str) {
  if (!str) return 0;
  return Math.max(0, Math.floor((Date.now() - new Date(str).getTime()) / 86400000));
}

function buildDisplayName(brand, category, productName, barcode) {
  brand = (brand||'').trim(); category = (category||'').trim(); productName = (productName||'').trim();
  if (brand && category) return `${brand} ${category}`;
  if (category) return category;
  if (productName) return productName;
  return barcode || '';
}

function appAlert(msg) {
  return new Promise(resolve => {
    const o = document.createElement('div');
    o.className = 'modal-overlay open';
    o.innerHTML = `<div class="modal-box"><div class="modal-msg">${escapeHtml(msg)}</div>
      <button class="btn btn-primary btn-block" id="_ok">확인</button></div>`;
    document.body.appendChild(o);
    const close = () => { o.remove(); resolve(); };
    o.querySelector('#_ok').onclick = close;
    o.onclick = e => { if (e.target === o) close(); };
  });
}

function appConfirm(msg) {
  return new Promise(resolve => {
    const o = document.createElement('div');
    o.className = 'modal-overlay open';
    o.innerHTML = `<div class="modal-box"><div class="modal-msg">${escapeHtml(msg)}</div>
      <div style="display:flex;gap:8px;margin-top:16px">
        <button class="btn btn-outline flex-1" id="_cancel">취소</button>
        <button class="btn btn-primary flex-1" id="_ok">확인</button>
      </div></div>`;
    document.body.appendChild(o);
    const close = r => { o.remove(); resolve(r); };
    o.querySelector('#_ok').onclick = () => close(true);
    o.querySelector('#_cancel').onclick = () => close(false);
    o.onclick = e => { if (e.target === o) close(false); };
  });
}

// ── 바코드 정규화 (스캐너 한글 자모 역변환) ─────────────────────────────────

function normalizeBarcode(input) {
  const JAMO = {'ㄱ':'r','ㄲ':'R','ㄴ':'s','ㄷ':'e','ㄸ':'E','ㄹ':'f','ㅁ':'a','ㅂ':'q','ㅃ':'Q','ㅅ':'t','ㅆ':'T','ㅇ':'','ㅈ':'w','ㅉ':'W','ㅊ':'c','ㅋ':'z','ㅌ':'x','ㅍ':'v','ㅎ':'g','ㅏ':'k','ㅐ':'o','ㅑ':'i','ㅒ':'O','ㅓ':'j','ㅔ':'p','ㅕ':'u','ㅖ':'P','ㅗ':'h','ㅘ':'hk','ㅙ':'ho','ㅚ':'hl','ㅛ':'y','ㅜ':'n','ㅝ':'nj','ㅞ':'np','ㅟ':'nl','ㅠ':'b','ㅡ':'m','ㅢ':'ml','ㅣ':'l','ㄳ':'rt','ㄵ':'sw','ㄶ':'sg','ㄺ':'fr','ㄻ':'fa','ㄼ':'fq','ㄽ':'ft','ㄾ':'fx','ㄿ':'fv','ㅀ':'fg','ㅄ':'qt'};
  const INI = ['ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ','ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'];
  const VOW = ['ㅏ','ㅐ','ㅑ','ㅒ','ㅓ','ㅔ','ㅕ','ㅖ','ㅗ','ㅘ','ㅙ','ㅚ','ㅛ','ㅜ','ㅝ','ㅞ','ㅟ','ㅠ','ㅡ','ㅢ','ㅣ'];
  const FIN = ['','ㄱ','ㄲ','ㄳ','ㄴ','ㄵ','ㄶ','ㄷ','ㄹ','ㄺ','ㄻ','ㄼ','ㄽ','ㄾ','ㄿ','ㅀ','ㅁ','ㅂ','ㅄ','ㅅ','ㅆ','ㅇ','ㅈ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'];
  let r = '';
  for (const ch of input) {
    const code = ch.charCodeAt(0);
    if (code >= 0xAC00 && code <= 0xD7A3) {
      const off = code - 0xAC00;
      r += JAMO[INI[Math.floor(off/(21*28))]]??'';
      r += JAMO[VOW[Math.floor((off%(21*28))/28)]]??'';
      const fi = off%28; if (fi>0) r += JAMO[FIN[fi]]??'';
    } else if (code >= 0x3130 && code <= 0x318F) {
      r += JAMO[ch]??ch;
    } else { r += ch; }
  }
  return r.toUpperCase().trim();
}

// ── 앱 상태 ──────────────────────────────────────────────────────────────────

const S = {
  store: '',
  threshold: 60,
  threshold2: null,   // optional second tier (rotation warning)
  operator: '',
  items: new Map(),    // barcode → itemData
  selected: new Set(),
  priceOriginal: [],
  lastChanges: [],
  directMode: false,
  currentHanger: 1,
};

// ── 화면 전환 ─────────────────────────────────────────────────────────────────

const STEPS = ['setup','scan','process','price','move'];
function showStep(id) {
  STEPS.forEach(s => { document.getElementById(`step-${s}`).style.display = s===id ? 'block':'none'; });
}

// ── STEP 1: 설정 ─────────────────────────────────────────────────────────────

async function initSetup() {
  const forceDirect = new URLSearchParams(location.search).get('direct') === '1';
  if (forceDirect) {
    document.body.classList.add('direct-mode');
    document.getElementById('threshold-group').style.display = 'none';
    document.querySelector('#step-setup .app-header h1').textContent = '가격수정';
    document.querySelector('#step-setup .app-title-sub').textContent = '바코드 스캔 → 바로 가격수정';
  }

  const sel = document.getElementById('store-select');
  sel.innerHTML = '<option value="">로딩 중...</option>';
  const opSel = document.getElementById('operator-input');
  opSel.innerHTML = '<option value="">로딩 중...</option>';

  const [{ data: locs, error }, { data: handlers, error: handlerError }] = await Promise.all([
    sb.from('locations').select('name').eq('is_active', true).neq('name', '폐기').order('name'),
    sb.from('handlers').select('name').eq('is_active', true).order('name'),
  ]);
  if (error || !locs?.length) {
    sel.innerHTML = '<option value="">매장 정보 로드 실패</option>'; return;
  }
  sel.innerHTML = '<option value="">매장을 선택하세요</option>' +
    locs.map(l => `<option value="${escapeHtml(l.name)}">${escapeHtml(l.name)}</option>`).join('');

  if (handlerError || !handlers?.length) {
    opSel.innerHTML = '<option value="">담당자 정보 로드 실패</option>';
  } else {
    opSel.innerHTML = '<option value="">담당자를 선택하세요</option>' +
      handlers.map(h => `<option value="${escapeHtml(h.name)}">${escapeHtml(h.name)}</option>`).join('');
  }

  function startScan({ direct = false } = {}) {
    const store = sel.value;
    const operator = opSel.value;
    if (!store) { appAlert('매장을 선택해주세요.'); return; }
    if (!operator) { appAlert('담당자를 선택해주세요.'); return; }
    if (direct) {
      S.store = store; S.threshold = 60; S.threshold2 = null;
      S.operator = operator; S.directMode = true;
    } else {
      const threshold = parseInt(document.getElementById('threshold-input').value) || 60;
      const t2raw = parseInt(document.getElementById('threshold2-input').value);
      const threshold2 = t2raw > 0 ? t2raw : null;
      if (threshold2 !== null && threshold2 >= threshold) {
        appAlert('순환필요 기준일은 가격변경 기준일보다 작아야 합니다.'); return;
      }
      S.store = store; S.threshold = threshold; S.threshold2 = threshold2;
      S.operator = operator; S.directMode = false;
    }
    S.items = new Map(); S.selected = new Set(); S.currentHanger = 1;
    showStep('scan');
    initScanStep();
  }

  document.getElementById('start-btn').onclick = () => startScan({ direct: forceDirect });
}

// ── STEP 2: 스캔 ─────────────────────────────────────────────────────────────

function initScanStep() {
  const labelSuffix = S.directMode
    ? '직접 가격수정'
    : S.threshold2 !== null
      ? `기준 🟠${S.threshold2}일 / 🔴${S.threshold}일`
      : `기준 ${S.threshold}일`;
  document.getElementById('scan-store-label').textContent = `${S.store} · ${labelSuffix}`;
  renderScanList();

  // 기존 리스너 제거 후 새로 연결
  const old = document.getElementById('scan-input');
  const inp = old.cloneNode(true);
  old.parentNode.replaceChild(inp, old);
  inp.value = '';

  let timer = null;
  function tryAdd(val) {
    const bc = normalizeBarcode(val);
    if (!bc) return;
    inp.value = '';
    if (!S.items.has(bc)) addItemToScan(bc);
  }
  inp.addEventListener('keydown', e => { if (e.key==='Enter') { e.preventDefault(); clearTimeout(timer); tryAdd(inp.value); }});
  inp.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => tryAdd(inp.value), 500); });
  inp.addEventListener('compositionend', () => { clearTimeout(timer); timer = setTimeout(() => tryAdd(inp.value), 500); });

  // 입력 탭 전환
  document.querySelectorAll('.input-tab').forEach(tab => {
    tab.onclick = () => {
      document.querySelectorAll('.input-tab').forEach(t => t.classList.remove('active'));
      ['scan','manual','paste'].forEach(id => {
        document.getElementById(`tab-panel-${id}`).style.display = id === tab.dataset.tab ? 'block' : 'none';
      });
      tab.classList.add('active');
      if (tab.dataset.tab === 'scan') setTimeout(() => inp.focus(), 50);
      else if (tab.dataset.tab === 'manual') setTimeout(() => document.getElementById('manual-input').focus(), 50);
    };
  });

  // 수동입력 탭
  const manualInp = document.getElementById('manual-input');
  const addManual = () => {
    const bc = normalizeBarcode(manualInp.value);
    manualInp.value = '';
    if (!bc) return;
    if (!S.items.has(bc)) addItemToScan(bc);
    manualInp.focus();
  };
  document.getElementById('manual-add-btn').onclick = addManual;
  manualInp.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); addManual(); } });

  // 붙여넣기 탭
  document.getElementById('paste-add-btn').onclick = () => {
    const ta = document.getElementById('paste-area');
    ta.value.split(/[\n,\s]+/).map(s => normalizeBarcode(s)).filter(Boolean).forEach(bc => {
      if (!S.items.has(bc)) addItemToScan(bc);
    });
    ta.value = '';
  };

  document.getElementById('scan-back-btn').onclick = async () => {
    if (S.items.size > 0) {
      const ok = await appConfirm('매장 선택으로 돌아가면 스캔된 바코드가 모두 사라집니다.\n계속할까요?');
      if (!ok) return;
    }
    clearSavedState();
    S.items = new Map(); S.currentHanger = 1;
    showStep('setup');
  };
  document.getElementById('hanger-done-btn').onclick = () => {
    S.currentHanger += 1;
    updateHangerBar();
  };
  document.getElementById('process-btn').onclick = () => {
    const valid = [...S.items.values()].filter(i => !i.loading && !i.notFound && !i.error);
    if (!valid.length) { appAlert('스캔된 바코드가 없습니다.'); return; }
    showStep('process');
    initProcessStep();
  };

  setTimeout(() => inp.focus(), 100);
}

async function addItemToScan(barcode) {
  const hangerNumber = S.currentHanger;
  S.items.set(barcode, { barcode, loading: true, hangerNumber });
  renderScanList();

  try {
    const [{ data: item, error }, { data: moves }, { data: priceHistory }] = await Promise.all([
      sb.from('inventory_items')
        .select('price,brand,category,product_name,location,created_at,status')
        .eq('barcode', barcode).maybeSingle(),
      sb.from('session_items')
        .select('move_sessions!inner(session_date,to_location)')
        .eq('barcode', barcode),
      sb.from('price_changes')
        .select('old_price,new_price,changed_at')
        .eq('barcode', barcode)
        .order('changed_at', { ascending: false })
        .limit(1),
    ]);

    if (error || !item) {
      S.items.set(barcode, { barcode, notFound: true, hangerNumber }); renderScanList(); return;
    }

    const currentLoc = item.location || S.store;
    let arrivalStr = item.created_at;
    if (moves?.length) {
      const locMoves = moves
        .filter(m => m.move_sessions?.to_location === currentLoc)
        .sort((a,b) => new Date(b.move_sessions.session_date) - new Date(a.move_sessions.session_date));
      if (locMoves.length) arrivalStr = locMoves[0].move_sessions.session_date;
    }

    const daysInStore = daysDiff(arrivalStr);
    const totalDays   = daysDiff(item.created_at);
    const lastChange = priceHistory?.[0] ?? null;
    S.items.set(barcode, {
      barcode,
      hangerNumber,
      price: item.price || 0,
      displayName: buildDisplayName(item.brand, item.category, item.product_name, barcode),
      location: item.location || '-',
      createdAt: item.created_at,
      arrivalDate: arrivalStr,
      daysInStore,
      totalDays,
      tier: daysInStore >= S.threshold ? 2
          : S.threshold2 !== null && daysInStore >= S.threshold2 ? 1
          : 0,
      locMismatch: !!(item.location && item.location !== S.store),
      status: item.status,
      lastPriceChange: lastChange ? {
        oldPrice: lastChange.old_price,
        newPrice: lastChange.new_price,
        daysAgo: daysDiff(lastChange.changed_at),
      } : null,
    });
  } catch(e) {
    S.items.set(barcode, { barcode, error: e.message, hangerNumber });
  }
  renderScanList();
}

function updateHangerBar() {
  const all = [...S.items.values()].filter(i => !i.loading && !i.notFound && !i.error);
  const curCount = all.filter(i => i.hangerNumber === S.currentHanger).length;
  const doneHangers = S.currentHanger - 1;
  document.getElementById('hanger-info').textContent = doneHangers > 0
    ? `행거 ${S.currentHanger} · ${curCount}개 (완료 ${doneHangers}개 행거)`
    : `행거 ${S.currentHanger} · ${curCount}개`;
  document.getElementById('hanger-done-btn').disabled = curCount === 0;
}

function renderScanList() {
  const all = [...S.items.values()];
  const valid = all.filter(i => !i.loading && !i.notFound && !i.error);
  const alertParts = [];
  if (!S.directMode) {
    const t2Count = valid.filter(i => i.tier === 2).length;
    const t1Count = valid.filter(i => i.tier === 1).length;
    if (t2Count) alertParts.push(`🔴 가격변경 ${t2Count}개`);
    if (t1Count) alertParts.push(`🟠 순환필요 ${t1Count}개`);
  }

  document.getElementById('scan-count').textContent =
    `${valid.length}개 스캔됨${alertParts.length ? ' · ' + alertParts.join(' · ') : ''}`;
  document.getElementById('process-btn').disabled = valid.length === 0;

  const sorted = [...all].reverse();

  const list = document.getElementById('scan-list');
  list.innerHTML = sorted.map(item => {
    const rm = `<button class="remove-btn" data-bc="${escapeHtml(item.barcode)}">×</button>`;
    if (item.loading) return `<div class="scan-card"><span class="bc-text">${escapeHtml(item.barcode)}</span> <span class="muted">조회 중...</span></div>`;
    if (item.notFound) return `<div class="scan-card card-err"><div class="row-sb"><span class="bc-text">${escapeHtml(item.barcode)}</span>${rm}</div><div class="err-text">⚠ DB에서 찾을 수 없음</div></div>`;
    if (item.error) return `<div class="scan-card card-err"><div class="row-sb"><span class="bc-text">${escapeHtml(item.barcode)}</span>${rm}</div><div class="err-text">${escapeHtml(item.error)}</div></div>`;

    const soldTag = item.status==='sold' ? '<span class="sold-tag">판매됨</span>' : '';

    const tierCls = item.tier === 2 ? ' card-lt2' : item.tier === 1 ? ' card-lt1' : '';
    const daysCls  = item.tier === 2 ? ' days-lt2' : item.tier === 1 ? ' days-lt1' : '';
    return `<div class="scan-card${tierCls}">
      <div class="card-top">
        <div class="card-main">
          <div class="item-name">${escapeHtml(item.displayName)}</div>
          <div class="card-sub">
            <span class="bc-text">${escapeHtml(item.barcode)}</span>
            <span class="dot-sep">·</span>
            <span class="loc-text">${escapeHtml(item.location)}</span>
            ${soldTag}
          </div>
        </div>
        <div class="card-right">${rm}</div>
      </div>
      <div class="card-price">${item.price.toLocaleString()}<span class="unit">원</span></div>
      <div class="days-text">
        <span class="days-store${daysCls}">여기온지 ${item.daysInStore}일 됐어요</span>
        <span class="days-sep">·</span>
        <span class="days-total">안팔린지 ${item.totalDays}일째 😢</span>
      </div>
      <div class="date-row">
        <span class="date-pill date-initial">최초입고 ${fmtDate(item.createdAt)}</span>
        <span class="date-pill date-arrival">이 매장 ${fmtDate(item.arrivalDate)}</span>
      </div>
      ${item.locMismatch ? `<div class="loc-warn">⚠ 기록된 위치는 <strong>${escapeHtml(item.location)}</strong> — 이동 누락 확인 필요</div>` : ''}
      ${item.lastPriceChange ? `<div class="price-history">📉 ${item.lastPriceChange.oldPrice.toLocaleString()}원 → ${item.lastPriceChange.newPrice.toLocaleString()}원으로 수정한 지 ${item.lastPriceChange.daysAgo}일 지났습니다</div>` : ''}
    </div>`;
  }).join('') || '<div class="empty-msg">바코드를 스캔하면 여기에 표시됩니다</div>';

  list.querySelectorAll('.remove-btn').forEach(btn => {
    btn.onclick = () => { S.items.delete(btn.dataset.bc); renderScanList(); };
  });

  updateHangerBar();
  saveState();
}

// ── STEP 3: 처리 ─────────────────────────────────────────────────────────────

function initProcessStep() {
  const all = [...S.items.values()].filter(i => !i.loading && !i.notFound && !i.error);
  const t2  = all.filter(i => i.tier === 2).sort((a,b) => b.daysInStore - a.daysInStore);
  const t1  = all.filter(i => i.tier === 1).sort((a,b) => b.daysInStore - a.daysInStore);
  const ok  = all.filter(i => i.tier === 0).sort((a,b) => b.daysInStore - a.daysInStore);

  // directMode: 전체 선택, 일반 모드: tier2(가격변경) 자동 선택
  // 선택 목록 자체는 스캔한 순서(all 기준)를 유지 — 화면 표시용 t2/t1/ok만 daysInStore 순 정렬
  S.selected = S.directMode
    ? new Set(all.map(i => i.barcode))
    : new Set(all.filter(i => i.tier === 2).map(i => i.barcode));

  let html = `<div class="page-header">
    <button class="back-btn" id="proc-back">← 스캔으로</button>
    <span class="page-title">처리할 물건 선택</span>
  </div>`;

  if (t2.length) {
    html += `<div class="section-hd red-hd">🔴 가격변경 ${t2.length}개 (${S.threshold}일 초과)</div>`;
    html += t2.map(i => processCard(i)).join('');
  }
  if (t1.length) {
    const gap = t2.length ? 'margin-top:12px' : '';
    html += `<div class="section-hd" style="color:var(--warn);${gap}">🟠 순환필요 ${t1.length}개 (${S.threshold2}일 초과)</div>`;
    html += t1.map(i => processCard(i)).join('');
  }
  if (ok.length) {
    const gap = (t2.length || t1.length) ? 'margin-top:12px' : '';
    html += `<div class="section-hd green-hd" style="${gap}">🟢 정상 ${ok.length}개</div>`;
    html += ok.map(i => processCard(i)).join('');
  }

  html += `<div class="action-bar">
    <span id="sel-count" class="sel-count">${S.selected.size}개 선택됨</span>
    <button class="btn btn-price" id="goto-price" ${S.selected.size?'':'disabled'}>💰 가격수정</button>
    <button class="btn btn-move"  id="goto-move"  ${S.selected.size?'':'disabled'}>📦 이동복사</button>
  </div>`;

  const el = document.getElementById('step-process');
  el.innerHTML = html;

  el.querySelector('#proc-back').onclick = () => showStep('scan');
  el.querySelectorAll('.proc-cb').forEach(cb => {
    cb.checked = S.selected.has(cb.dataset.bc);
    cb.onchange = () => {
      cb.checked ? S.selected.add(cb.dataset.bc) : S.selected.delete(cb.dataset.bc);
      updateProcActions();
    };
  });
  el.querySelector('#goto-price').onclick = () => { showStep('price'); initPriceStep(); };
  el.querySelector('#goto-move').onclick  = () => { showStep('move');  initMoveStep();  };
}

function processCard(item) {
  const chk = S.selected.has(item.barcode) ? 'checked' : '';
  const tierCls = item.tier === 2 ? ' card-lt2' : item.tier === 1 ? ' card-lt1' : '';
  const daysCls  = item.tier === 2 ? ' days-lt2' : item.tier === 1 ? ' days-lt1' : '';
  return `<label class="proc-card${tierCls}">
    <input type="checkbox" class="proc-cb" data-bc="${escapeHtml(item.barcode)}" ${chk}>
    <div class="proc-info">
      <div class="item-name">${escapeHtml(item.displayName)}</div>
      <div class="card-sub" style="margin-top:3px">
        <span class="bc-text">${escapeHtml(item.barcode)}</span>
      </div>
      <div class="card-price" style="margin-top:8px">${item.price.toLocaleString()}<span class="unit">원</span></div>
      <div class="days-text">
        <span class="days-store${daysCls}">여기온지 ${item.daysInStore}일 됐어요</span>
        <span class="days-sep">·</span>
        <span class="days-total">안팔린지 ${item.totalDays}일째 😢</span>
      </div>
      <div class="date-row">
        <span class="date-pill date-initial">최초입고 ${fmtDate(item.createdAt)}</span>
        <span class="date-pill date-arrival">이 매장 ${fmtDate(item.arrivalDate)}</span>
      </div>
    </div>
  </label>`;
}

function updateProcActions() {
  document.getElementById('sel-count').textContent = `${S.selected.size}개 선택됨`;
  document.getElementById('goto-price').disabled = S.selected.size === 0;
  document.getElementById('goto-move').disabled  = S.selected.size === 0;
}

// ── STEP 4A: 가격수정 ────────────────────────────────────────────────────────

function initPriceStep() {
  S.priceModeByHanger = {};
  S.priceOriginal = [...S.selected].map(bc => {
    const item = S.items.get(bc);
    return { barcode: bc, oldPrice: item?.price||0, displayName: item?.displayName||bc, hangerNumber: item?.hangerNumber ?? 1 };
  });

  // 행거번호가 바뀌는 지점마다 새 그룹 시작(스캔 순서상 행거번호는 항상 비내림차순이라 인접 그룹핑으로 충분)
  // — 행거별로 수정방식(개별/일괄%/일괄동일가)을 따로 고를 수 있도록 그룹 단위로 렌더링한다.
  const groups = [];
  S.priceOriginal.forEach((item, i) => {
    const last = groups[groups.length - 1];
    if (last && last.hangerNumber === item.hangerNumber) last.indices.push(i);
    else groups.push({ hangerNumber: item.hangerNumber, indices: [i] });
  });
  S.priceGroups = groups;

  let html = `<div class="page-header">
    <button class="back-btn" id="price-back">← 선택으로</button>
    <span class="page-title">가격수정 (${S.priceOriginal.length}개)</span>
  </div>
  <div class="slack-notice">⚠️ Slack <strong>공동판매 사용중</strong> 채널에 <strong>현재 사용중</strong> 메시지를 먼저 남기세요.</div>`;

  html += groups.map(g => `
    <div class="hanger-group">
      <div class="section-hd">🏷 ${g.hangerNumber}번 행거 · ${g.indices.length}개</div>
      <div class="mode-bar">
        <button class="mode-btn active" data-hanger="${g.hangerNumber}" data-mode="individual">개별 수정</button>
        <button class="mode-btn" data-hanger="${g.hangerNumber}" data-mode="bulk-pct">일괄 % 수정</button>
        <button class="mode-btn" data-hanger="${g.hangerNumber}" data-mode="bulk-fixed">일괄 동일가 수정</button>
      </div>
      <div class="bulk-box" id="bulk-box-pct-${g.hangerNumber}">
        <div class="row-gap">
          <span style="color:#fbbf24;font-weight:600">할인율</span>
          <input class="bulk-input" id="bulk-pct-${g.hangerNumber}" type="number" min="1" max="99" placeholder="30">
          <span style="color:#fbbf24;font-weight:700">%</span>
          <span class="muted" style="font-size:12px">반올림 천원 단위</span>
        </div>
      </div>
      <div class="bulk-box" id="bulk-box-fixed-${g.hangerNumber}">
        <div class="row-gap">
          <span style="color:#fbbf24;font-weight:600">동일 가격</span>
          <input class="bulk-input" id="bulk-fixed-${g.hangerNumber}" type="number" min="0" step="1000" placeholder="10000" style="width:96px">
          <span style="color:#fbbf24;font-weight:700">원</span>
        </div>
      </div>
      ${g.indices.map(i => {
        const item = S.priceOriginal[i];
        return `<div class="item-card">
          <div class="row-gap" style="margin-bottom:6px">
            <span class="bc-text">${escapeHtml(item.barcode)}</span>
            <span class="muted">${escapeHtml(item.displayName)}</span>
          </div>
          <div class="row-gap">
            <span class="price-old" id="old-${i}">${item.oldPrice.toLocaleString()}</span>
            <span class="muted">→</span>
            <input class="price-input" id="new-${i}" type="number" step="1000" min="0"
                   placeholder="${item.oldPrice}" data-original="${item.oldPrice}">
            <span class="muted">원</span>
            <button class="pct-quick-btn" data-index="${i}" data-pct="30">30%</button>
            <button class="pct-quick-btn" data-index="${i}" data-pct="50">50%</button>
            <button class="pct-quick-btn" data-index="${i}" data-pct="70">70%</button>
          </div>
        </div>`;
      }).join('')}
    </div>`).join('');

  html += `<button class="btn btn-price btn-block" id="price-apply" style="margin-top:16px">✅ 수정 적용하기</button>
  <div class="modal-overlay" id="price-modal">
    <div class="modal-box">
      <div style="font-weight:700;margin-bottom:12px">⚠️ 가격 수정 확인</div>
      <div id="price-summary" class="modal-msg"></div>
      <div style="display:flex;gap:8px;margin-top:16px">
        <button class="btn btn-outline flex-1" id="price-cancel">취소</button>
        <button class="btn btn-price flex-1" id="price-confirm">수정 적용</button>
      </div>
    </div>
  </div>
  <div id="price-done" style="display:none;margin-top:14px">
    <div class="success-box">
      <div style="font-weight:700;margin-bottom:10px">✅ 가격 수정 완료</div>
      <div id="bulk-notice" class="muted" style="display:none;margin-bottom:12px;font-size:13px">
        일괄 할인된 물건에는 <strong>해당 %가 표시된 스티커</strong>를 기존 바코드 위에 붙여주세요.
      </div>
      <button class="btn btn-green btn-block" id="zpl-btn" style="display:none">🖨 수정된 라벨 ZPL 다운로드</button>
      <button class="btn btn-kiosk btn-block" id="kiosk-btn" style="margin-top:8px">📥 키오스크 업로드 파일 다운로드</button>
      <div id="kiosk-status" class="muted" style="font-size:12px;text-align:center;margin-top:6px"></div>
    </div>
  </div>`;

  const el = document.getElementById('step-price');
  el.innerHTML = html;

  el.querySelector('#price-back').onclick = () => { showStep('process'); initProcessStep(); };
  el.querySelectorAll('.mode-btn').forEach(btn => {
    btn.onclick = () => setHangerPriceMode(Number(btn.dataset.hanger), btn.dataset.mode);
  });
  groups.forEach(g => {
    document.getElementById(`bulk-pct-${g.hangerNumber}`).oninput   = () => applyHangerBulkPct(g.hangerNumber);
    document.getElementById(`bulk-fixed-${g.hangerNumber}`).oninput = () => applyHangerBulkFixed(g.hangerNumber);
  });
  el.querySelectorAll('.price-input').forEach(inp => inp.oninput = () => onPriceChange(inp));
  el.querySelectorAll('.pct-quick-btn').forEach(btn => {
    btn.onclick = () => applyItemPct(Number(btn.dataset.index), Number(btn.dataset.pct));
  });
  el.querySelector('#price-apply').onclick  = openPriceConfirm;
  el.querySelector('#price-cancel').onclick = () => el.querySelector('#price-modal').classList.remove('open');
  el.querySelector('#price-confirm').onclick = submitPriceChanges;
}

function setHangerPriceMode(hangerNumber, mode) {
  S.priceModeByHanger[hangerNumber] = mode;
  document.querySelectorAll(`.mode-btn[data-hanger="${hangerNumber}"]`).forEach(b => {
    b.classList.toggle('active', b.dataset.mode === mode);
  });
  document.getElementById(`bulk-box-pct-${hangerNumber}`).classList.toggle('open', mode === 'bulk-pct');
  document.getElementById(`bulk-box-fixed-${hangerNumber}`).classList.toggle('open', mode === 'bulk-fixed');
  if (mode === 'individual') {
    const g = S.priceGroups.find(g => g.hangerNumber === hangerNumber);
    g.indices.forEach(i => {
      const inp = document.getElementById(`new-${i}`);
      if (inp) { inp.value = ''; onPriceChange(inp); }
    });
  }
}

function applyHangerBulkPct(hangerNumber) {
  const pct = parseFloat(document.getElementById(`bulk-pct-${hangerNumber}`).value);
  if (isNaN(pct) || pct<=0 || pct>=100) return;
  const g = S.priceGroups.find(g => g.hangerNumber === hangerNumber);
  g.indices.forEach(i => {
    const d = S.priceOriginal[i];
    const inp = document.getElementById(`new-${i}`);
    if (!inp) return;
    inp.value = Math.round((d.oldPrice * (1-pct/100)) / 1000) * 1000;
    onPriceChange(inp);
  });
}

function applyItemPct(i, pct) {
  const d = S.priceOriginal[i];
  const inp = document.getElementById(`new-${i}`);
  if (!inp) return;
  inp.value = Math.round((d.oldPrice * (1-pct/100)) / 1000) * 1000;
  onPriceChange(inp);
}

function applyHangerBulkFixed(hangerNumber) {
  const price = parseInt(document.getElementById(`bulk-fixed-${hangerNumber}`).value);
  if (isNaN(price) || price<0) return;
  const g = S.priceGroups.find(g => g.hangerNumber === hangerNumber);
  g.indices.forEach(i => {
    const inp = document.getElementById(`new-${i}`);
    if (!inp) return;
    inp.value = price;
    onPriceChange(inp);
  });
}

function onPriceChange(inp) {
  const val = parseInt(inp.value);
  inp.classList.toggle('changed', !isNaN(val) && val !== parseInt(inp.dataset.original));
}

function getChanges() {
  return S.priceOriginal.map((d, i) => {
    const inp = document.getElementById(`new-${i}`);
    if (!inp) return null;
    const newPrice = parseInt(inp.value);
    if (isNaN(newPrice) || newPrice===d.oldPrice || newPrice<=0) return null;
    return { barcode: d.barcode, oldPrice: d.oldPrice, newPrice };
  }).filter(Boolean);
}

function openPriceConfirm() {
  const changes = getChanges();
  if (!changes.length) { appAlert('변경된 가격이 없습니다.'); return; }
  document.getElementById('price-summary').textContent =
    `변경 ${changes.length}건:\n` + changes.map(c => `${c.barcode}: ${c.oldPrice.toLocaleString()} → ${c.newPrice.toLocaleString()}원`).join('\n');
  document.getElementById('price-modal').classList.add('open');
}

async function submitPriceChanges() {
  const btn = document.getElementById('price-confirm');
  btn.disabled = true; btn.textContent = '⏳ 처리 중...';
  const changes = getChanges();
  try {
    const now = Date.now();
    // changed_at을 항목마다 1ms씩 늘려서 부여 — 동일 시각으로 저장하면 나중에 라벨 출력 정렬 시
    // 동률 처리 순서가 보장되지 않아 체크한 순서와 다르게 출력되는 문제 방지
    const { error } = await sb.from('price_changes').insert(
      changes.map((c, i) => ({
        barcode:c.barcode, old_price:c.oldPrice, new_price:c.newPrice,
        changed_by: S.operator || null, changed_at: new Date(now + i).toISOString(), excel_updated:false,
        hanger_number: S.items.get(c.barcode)?.hangerNumber ?? null,
        store: S.store || null,
      }))
    );
    if (error) throw error;

    document.getElementById('price-modal').classList.remove('open');
    S.lastChanges = changes;

    // 로컬 캐시 업데이트
    changes.forEach(c => {
      const item = S.items.get(c.barcode);
      if (item) { item.price = c.newPrice; S.items.set(c.barcode, item); }
      const orig = S.priceOriginal.find(p => p.barcode===c.barcode);
      if (orig) orig.oldPrice = c.newPrice;
    });

    const done = document.getElementById('price-done');
    done.style.display = 'block';
    done.scrollIntoView({ behavior:'smooth', block:'center' });

    // 완료 후 뒤로가기 → 홈(매장선택)으로
    const backBtn = document.getElementById('price-back');
    backBtn.textContent = '← 홈으로';
    backBtn.onclick = () => { clearSavedState(); S.items = new Map(); showStep('setup'); initSetup(); };

    if (Object.values(S.priceModeByHanger).some(m => m === 'bulk-pct')) {
      document.getElementById('bulk-notice').style.display = 'block';
    }
    const zplBtn = document.getElementById('zpl-btn');
    zplBtn.style.display = 'block';
    zplBtn.onclick = () => {
      const barcodesStr = encodeURIComponent(changes.map(c=>c.barcode).join(','));
      const overridesStr = encodeURIComponent(changes.map(c=>`${c.barcode}:${c.newPrice}`).join(','));
      window.open(`labels.html?barcodes=${barcodesStr}&price_overrides=${overridesStr}`, '_blank');
    };

    document.getElementById('kiosk-btn').onclick = downloadKioskFile;
  } catch(e) {
    await appAlert('오류: ' + e.message);
  } finally {
    btn.disabled = false; btn.textContent = '수정 적용';
  }
}

function downloadKioskFile() {
  const btn = document.getElementById('kiosk-btn');
  const status = document.getElementById('kiosk-status');

  const ws = XLSX.utils.aoa_to_sheet([
    ['바코드', '판매단가'],
    ...S.lastChanges.map(c => [c.barcode, c.newPrice]),
  ]);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, 'Sheet1');
  const dateStr = new Date().toISOString().slice(0, 10);
  XLSX.writeFile(wb, `kiosk_upload_${dateStr}.xlsx`);

  btn.textContent = '✅ 다운로드 완료';
  btn.style.background = '#166534';
  status.textContent = `${S.lastChanges.length}개 · 키오스크 관리사이트에서 수동으로 업로드해주세요`;
  status.style.color = '#166534';
  status.style.fontWeight = '500';
}

// ── STEP 4B: 이동 복사 ───────────────────────────────────────────────────────

function initMoveStep() {
  const barcodes = [...S.selected];
  const items = barcodes.map(bc => S.items.get(bc)).filter(Boolean);

  document.getElementById('step-move').innerHTML = `
    <div class="page-header">
      <button class="back-btn" id="move-back">← 선택으로</button>
      <span class="page-title">이동복사 (${barcodes.length}개)</span>
    </div>
    <div class="move-list">
      ${items.map(i => `<div class="move-item">
        <span class="bc-text">${escapeHtml(i.barcode)}</span>
        <span class="muted">${escapeHtml(i.displayName)}</span>
      </div>`).join('')}
    </div>
    <button class="btn btn-move btn-block" id="copy-btn" style="margin-top:16px">📋 바코드 클립보드 복사</button>
    <div id="copy-status" style="display:none;color:#22c55e;text-align:center;margin-top:8px;font-size:13px">
      ✅ 복사됨! 이동앱에서 붙여넣기 하세요.
    </div>`;

  document.getElementById('move-back').onclick = () => { showStep('process'); initProcessStep(); };
  document.getElementById('copy-btn').onclick = async () => {
    try {
      await navigator.clipboard.writeText(barcodes.join('\n'));
      document.getElementById('copy-status').style.display = 'block';
      document.getElementById('copy-btn').textContent = '✅ 복사됨';
    } catch(e) {
      appAlert('클립보드 복사 실패.\n수동으로 복사해주세요:\n\n' + barcodes.join('\n'));
    }
  };
}

// ── sessionStorage 저장/복구 ─────────────────────────────────────────────────

const STORAGE_KEY = 'miu-longterm-state';

function saveState() {
  // loading 중인 항목은 제외하고 저장
  const items = [...S.items.entries()].filter(([, v]) => !v.loading);
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify({
    store: S.store,
    operator: S.operator,
    threshold: S.threshold,
    threshold2: S.threshold2,
    directMode: S.directMode,
    currentHanger: S.currentHanger,
    items,
  }));
}

function loadSavedState() {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return false;
    const data = JSON.parse(raw);
    if (!data.store) return false;
    S.store = data.store;
    S.operator = data.operator || '';
    S.threshold = data.threshold || 60;
    S.threshold2 = data.threshold2 ?? null;
    S.directMode = data.directMode ?? false;
    S.currentHanger = data.currentHanger || 1;
    S.items = new Map(data.items || []);
    return true;
  } catch(e) {
    return false;
  }
}

function clearSavedState() {
  sessionStorage.removeItem(STORAGE_KEY);
}

// ── 초기화 ───────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  if (loadSavedState() && S.store) {
    document.body.classList.toggle('direct-mode', S.directMode);
    showStep('scan');
    initScanStep();
  } else {
    showStep('setup');
    initSetup();
  }
});
