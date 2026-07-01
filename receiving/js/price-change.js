// ── 한글 자모 → 영어 역변환 (스캐너용) ───────────────────────────────────────
function normalizeBarcode(input) {
  const JAMO_TO_ENG = {
    'ㄱ':'r','ㄲ':'R','ㄴ':'s','ㄷ':'e','ㄸ':'E','ㄹ':'f','ㅁ':'a','ㅂ':'q','ㅃ':'Q',
    'ㅅ':'t','ㅆ':'T','ㅇ':'','ㅈ':'w','ㅉ':'W','ㅊ':'c','ㅋ':'z','ㅌ':'x','ㅍ':'v','ㅎ':'g',
    'ㅏ':'k','ㅐ':'o','ㅑ':'i','ㅒ':'O','ㅓ':'j','ㅔ':'p','ㅕ':'u','ㅖ':'P',
    'ㅗ':'h','ㅘ':'hk','ㅙ':'ho','ㅚ':'hl','ㅛ':'y',
    'ㅜ':'n','ㅝ':'nj','ㅞ':'np','ㅟ':'nl','ㅠ':'b',
    'ㅡ':'m','ㅢ':'ml','ㅣ':'l',
    'ㄳ':'rt','ㄵ':'sw','ㄶ':'sg','ㄺ':'fr','ㄻ':'fa','ㄼ':'fq',
    'ㄽ':'ft','ㄾ':'fx','ㄿ':'fv','ㅀ':'fg','ㅄ':'qt'
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

// ── 탭 ───────────────────────────────────────────────────────────────────────
document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    const tab = btn.dataset.tab;
    document.getElementById("panel-scan").classList.toggle("active", tab === "scan");
    document.getElementById("panel-manual").classList.toggle("active", tab === "manual");
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  });
});

// ── 바코드 추가 ──────────────────────────────────────────────────────────────
const scanned = [];
const scannedSet = new Set();

function addBarcode(bc) {
  if (!bc || scannedSet.has(bc)) return;
  scanned.push(bc); scannedSet.add(bc);
  renderList();
}
function removeBarcode(idx) {
  const bc = scanned.splice(idx, 1)[0];
  scannedSet.delete(bc);
  renderList();
}
function clearAll() {
  scanned.length = 0; scannedSet.clear(); renderList();
}
function renderList() {
  const list = document.getElementById("scan-list");
  const empty = document.getElementById("scan-empty");
  const count = scanned.length;
  document.getElementById("count").textContent = count;
  document.getElementById("lookup-btn").disabled = count === 0;
  document.getElementById("scan-box").classList.toggle("active", count > 0);
  if (count === 0) { list.innerHTML = ""; empty.style.display = "block"; return; }
  empty.style.display = "none";
  list.innerHTML = scanned.map((bc, i) =>
    `<div class="scan-row">
      <span class="scan-row-num">${i+1}</span>
      <span class="scan-row-bc">${escapeHtml(bc)}</span>
      <button class="scan-row-del" data-idx="${i}">×</button>
    </div>`).join("");
  list.querySelectorAll(".scan-row-del").forEach(b =>
    b.addEventListener("click", () => removeBarcode(parseInt(b.dataset.idx, 10)))
  );
}

const bi = document.getElementById("barcode-input");
let scanTimer = null;

bi.addEventListener("keydown", e => {
  if (e.key === "Enter") {
    e.preventDefault();
    clearTimeout(scanTimer);
    const v = normalizeBarcode(bi.value);
    bi.value = "";
    if (v) addBarcode(v);
  }
});
bi.addEventListener("input", () => {
  clearTimeout(scanTimer);
  scanTimer = setTimeout(() => {
    const v = normalizeBarcode(bi.value); bi.value = "";
    if (v) addBarcode(v);
  }, 500);
});
bi.addEventListener("compositionend", () => {
  clearTimeout(scanTimer);
  scanTimer = setTimeout(() => {
    const v = normalizeBarcode(bi.value); bi.value = "";
    if (v) addBarcode(v);
  }, 500);
});

document.getElementById("manual-barcode").addEventListener("keydown", e => {
  if (e.key === "Enter") {
    e.preventDefault();
    const v = normalizeBarcode(e.target.value); e.target.value = "";
    if (v) addBarcode(v);
  }
});

document.getElementById("paste-btn").addEventListener("click", () => {
  const ta = document.getElementById("paste-area");
  ta.value.split(/[\n,\s]+/).map(s => normalizeBarcode(s)).filter(Boolean).forEach(addBarcode);
  ta.value = "";
});

document.getElementById("clear-btn").addEventListener("click", clearAll);

// ── 조회 → 편집 화면 ─────────────────────────────────────────────────────────
document.getElementById("lookup-btn").addEventListener("click", async () => {
  const changed_by = document.getElementById("changed-by").value.trim();
  try {
    const [{ data: rows, error }, { data: soldRows, error: soldError }] = await Promise.all([
      sb.from("inventory_items").select("barcode, price, brand, category").in("barcode", scanned),
      sb.from("sold_items").select("barcode, sold_date, product_name").in("barcode", scanned),
    ]);
    if (error) throw error;
    if (soldError) throw soldError;

    if (soldRows && soldRows.length > 0) {
      const list = soldRows.map(r =>
        `${r.barcode}${r.product_name ? " (" + r.product_name + ")" : ""} — 판매일: ${r.sold_date || "미기재"}`
      ).join("\n");
      const ok = await appConfirm(`⚠️ 아래 바코드는 이미 판매된 상품입니다:\n\n${list}\n\n그래도 가격 수정을 계속 진행하시겠습니까?`);
      if (!ok) return;
    }

    const found = new Set((rows || []).map(r => r.barcode));
    const items = (rows || []).map(r => ({
      barcode:      r.barcode,
      price:        r.price || 0,
      display_name: r.brand || r.category || "",
    }));
    const not_found = scanned.filter(b => !found.has(b));
    renderEdit({ items, not_found }, changed_by);
  } catch (e) {
    showError("조회 실패: " + e.message);
  }
});

let originalData = [];
let CHANGED_BY = "";

function renderEdit(data, changedBy) {
  CHANGED_BY = changedBy;
  originalData = (data.items || []).map(item => ({
    barcode: item.barcode, oldPrice: item.price, displayName: item.display_name,
  }));

  document.getElementById("step1").style.display = "none";
  const c = document.getElementById("step2");
  c.style.display = "block";

  let html = `<a href="#" id="back-btn" class="back-btn">← 바코드 목록으로</a>`;

  if ((data.not_found || []).length > 0) {
    html += `<div class="warn-box"><strong>⚠ 입고 시트에서 찾지 못한 바코드 ${data.not_found.length}개</strong><br>${escapeHtml(data.not_found.join(", "))}</div>`;
  }

  if (originalData.length === 0) {
    html += `<div class="empty">조회된 상품이 없습니다</div>`;
    c.innerHTML = html;
    document.getElementById("back-btn").addEventListener("click", goBack);
    return;
  }

  html += `
    <div class="mode-bar">
      <button class="mode-btn active" id="mode-individual">개별 수정</button>
      <button class="mode-btn" id="mode-bulk">일괄 % 수정</button>
    </div>
    <div class="bulk-box" id="bulk-box">
      <div style="display:flex; align-items:center; gap:10px">
        <span style="font-size:14px; color:#fbbf24; font-weight:600">할인율</span>
        <input class="bulk-input" id="bulk-pct" type="number" min="1" max="99" placeholder="30">
        <span style="color:#fbbf24; font-weight:700">%</span>
        <span style="font-size:12px; color:#78350f">반올림 천원 단위</span>
      </div>
    </div>
  `;

  html += originalData.map((item, i) => `
    <div class="item-card">
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:8px">
        <span class="item-bc">${escapeHtml(item.barcode)}</span>
        <span style="font-size:13px; color:#94a3b8; flex:1">${escapeHtml(item.displayName || "")}</span>
      </div>
      <div style="display:flex; align-items:center; gap:8px">
        <span class="price-old" id="old-${i}">${item.oldPrice.toLocaleString()}</span>
        <span class="price-arrow">→</span>
        <input class="price-input" id="new-${i}" type="number" step="1000" min="0"
               value="${item.oldPrice}" data-original="${item.oldPrice}" data-idx="${i}">
        <span style="font-size:13px; color:#64748b">원</span>
      </div>
    </div>`).join("");

  html += `<div style="margin-top:16px">
    <button class="btn btn-warn btn-block" id="apply-btn">✅ 수정 적용하기</button>
  </div>`;

  html += `
    <div class="modal-overlay" id="modal">
      <div class="modal-box">
        <div class="modal-title">⚠️ 수정 전 확인하세요</div>
        <div class="modal-slack">
          <strong>Slack에 먼저 메시지를 보내주세요</strong><br>
          <strong>「지금 공동판매 엑셀 가격 수정 중입니다」</strong> 메시지를 보낸 후 진행해주세요.
        </div>
        <div id="modal-summary" style="font-size:13px; color:#94a3b8; margin-bottom:16px"></div>
        <div class="modal-btns">
          <button class="btn btn-outline flex-1" id="modal-cancel">취소</button>
          <button class="btn btn-warn flex-1" id="modal-confirm">수정 적용</button>
        </div>
      </div>
    </div>

    <div id="print-after" style="display:none; margin-top:14px">
      <div style="background:#0a2a18; border:1px solid #22c55e; border-radius:12px; padding:16px">
        <div class="success" style="font-weight:700; margin-bottom:10px">✅ 가격 수정 완료</div>
        <div style="font-size:13px; color:#64748b; margin-bottom:14px">
          수정된 바코드 라벨을 출력해서 기존 라벨 위에 붙여주세요.
        </div>
        <button class="btn btn-block" id="print-btn" style="background:#22c55e; color:#000; font-weight:800">🖨 수정된 라벨 출력</button>
      </div>
    </div>
  `;

  c.innerHTML = html;

  document.getElementById("back-btn").addEventListener("click", goBack);
  document.getElementById("mode-individual").addEventListener("click", () => setMode("individual"));
  document.getElementById("mode-bulk").addEventListener("click", () => setMode("bulk"));
  document.getElementById("bulk-pct").addEventListener("input", applyBulk);
  document.querySelectorAll(".price-input").forEach(inp => {
    inp.addEventListener("input", () => onPriceChange(inp));
  });
  document.getElementById("apply-btn").addEventListener("click", openConfirm);
  document.getElementById("modal-cancel").addEventListener("click", () => document.getElementById("modal").classList.remove("open"));
  document.getElementById("modal-confirm").addEventListener("click", submitChanges);
}

function goBack(e) {
  if (e) e.preventDefault();
  document.getElementById("step1").style.display = "block";
  document.getElementById("step2").style.display = "none";
}

function setMode(mode) {
  document.getElementById("mode-individual").classList.toggle("active", mode === "individual");
  document.getElementById("mode-bulk").classList.toggle("active", mode === "bulk");
  document.getElementById("bulk-box").classList.toggle("open", mode === "bulk");
  if (mode === "individual") {
    originalData.forEach((d, i) => {
      const inp = document.getElementById(`new-${i}`);
      if (inp) { inp.value = d.oldPrice; onPriceChange(inp); }
    });
  }
}

function applyBulk() {
  const pct = parseFloat(document.getElementById("bulk-pct").value);
  if (isNaN(pct) || pct <= 0 || pct >= 100) return;
  originalData.forEach((d, i) => {
    const inp = document.getElementById(`new-${i}`);
    if (!inp) return;
    const rounded = Math.round((d.oldPrice * (1 - pct/100)) / 1000) * 1000;
    inp.value = rounded; onPriceChange(inp);
  });
}

function onPriceChange(inp) {
  const orig = parseInt(inp.dataset.original);
  const val  = parseInt(inp.value);
  inp.classList.toggle("changed", !isNaN(val) && val !== orig);
}

function getChanges() {
  return originalData.map((d, i) => {
    const inp = document.getElementById(`new-${i}`);
    if (!inp) return null;
    const newPrice = parseInt(inp.value);
    if (isNaN(newPrice) || newPrice === d.oldPrice || newPrice <= 0) return null;
    return { barcode: d.barcode, oldPrice: d.oldPrice, newPrice };
  }).filter(Boolean);
}

function openConfirm() {
  const changes = getChanges();
  if (changes.length === 0) { appAlert("변경된 가격이 없습니다."); return; }
  const summary = changes.map(c => `${c.barcode}: ${c.oldPrice.toLocaleString()} → ${c.newPrice.toLocaleString()}원`).join("\n");
  document.getElementById("modal-summary").innerText = `변경 ${changes.length}건:\n${summary}`;
  document.getElementById("modal").classList.add("open");
}

async function submitChanges() {
  const btn = document.getElementById("modal-confirm");
  btn.disabled = true; btn.textContent = "⏳ 처리 중...";
  const changes = getChanges();
  try {
    const now = new Date().toISOString();
    const rows = changes.map(c => ({
      barcode:       c.barcode,
      old_price:     c.oldPrice,
      new_price:     c.newPrice,
      changed_by:    CHANGED_BY || null,
      changed_at:    now,
      excel_updated: false,
    }));
    const { error } = await sb.from("price_changes").insert(rows);
    if (error) throw error;
    {
      document.getElementById("modal").classList.remove("open");
      changes.forEach(c => {
        const i = originalData.findIndex(d => d.barcode === c.barcode);
        if (i >= 0) {
          originalData[i].oldPrice = c.newPrice;
          const inp = document.getElementById(`new-${i}`);
          if (inp) {
            inp.dataset.original = c.newPrice;
            document.getElementById(`old-${i}`).textContent = c.newPrice.toLocaleString();
            onPriceChange(inp);
          }
        }
      });
      const printAfter = document.getElementById("print-after");
      printAfter.style.display = "block";
      printAfter.scrollIntoView({ behavior: "smooth", block: "center" });
      document.getElementById("print-btn").onclick = () => {
        const barcodesStr = encodeURIComponent(changes.map(c => c.barcode).join(","));
        const overridesStr = encodeURIComponent(changes.map(c => `${c.barcode}:${c.newPrice}`).join(","));
        window.open(`labels.html?barcodes=${barcodesStr}&price_overrides=${overridesStr}`, "_blank");
      };
    }
  } catch (e) {
    await appAlert("오류: " + e.message);
  } finally {
    btn.disabled = false; btn.textContent = "수정 적용";
  }
}

setTimeout(() => bi.focus(), 200);
