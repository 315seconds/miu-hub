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

document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    const tab = btn.dataset.tab;
    document.getElementById("panel-scan").classList.toggle("active", tab === "scan");
    document.getElementById("panel-manual").classList.toggle("active", tab === "manual");
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  });
});

const scanned = [];
const scannedSet = new Set();

function addBarcode(bc) {
  if (!bc || scannedSet.has(bc)) return;
  scanned.push(bc); scannedSet.add(bc); renderList();
}
function removeBarcode(idx) {
  const bc = scanned.splice(idx, 1)[0]; scannedSet.delete(bc); renderList();
}
function clearAll() { scanned.length = 0; scannedSet.clear(); renderList(); }

function renderList() {
  const list  = document.getElementById("scan-list");
  const empty = document.getElementById("scan-empty");
  const count = scanned.length;
  document.getElementById("count").textContent = count;
  document.getElementById("print-btn").disabled = count === 0;
  document.getElementById("clear-btn").hidden = count === 0;
  document.getElementById("scan-box").classList.toggle("active", count > 0);
  if (count === 0) { list.innerHTML = ""; empty.style.display = "block"; return; }
  empty.style.display = "none";
  list.innerHTML = scanned.map((bc, i) =>
    `<div class="scan-row">
      <span class="scan-row-num">${i + 1}</span>
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
    e.preventDefault(); clearTimeout(scanTimer);
    const v = normalizeBarcode(bi.value); bi.value = "";
    if (v) addBarcode(v);
  }
});
bi.addEventListener("input", () => {
  clearTimeout(scanTimer);
  scanTimer = setTimeout(() => {
    const v = normalizeBarcode(bi.value); bi.value = ""; if (v) addBarcode(v);
  }, 500);
});
bi.addEventListener("compositionend", () => {
  clearTimeout(scanTimer);
  scanTimer = setTimeout(() => {
    const v = normalizeBarcode(bi.value); bi.value = ""; if (v) addBarcode(v);
  }, 500);
});
document.getElementById("manual-barcode").addEventListener("keydown", e => {
  if (e.key === "Enter") {
    e.preventDefault();
    const v = normalizeBarcode(e.target.value); e.target.value = ""; if (v) addBarcode(v);
  }
});
document.getElementById("paste-btn").addEventListener("click", () => {
  const ta = document.getElementById("paste-area");
  ta.value.split(/[\n,\s]+/).map(s => normalizeBarcode(s)).filter(Boolean).forEach(addBarcode);
  ta.value = "";
});
document.getElementById("clear-btn").addEventListener("click", clearAll);

// 세탁실 완료가 올린 대기열(scripts/laundry-room-20261116.sql). 출력하면 labels.js 가 대기열에서 뺀다.
document.getElementById("queue-btn").addEventListener("click", async () => {
  const msg = document.getElementById("queue-msg");
  msg.textContent = "불러오는 중…";
  const { data, error } = await sb.from("reprint_queue").select("barcode").is("printed_at", null).order("queued_at");
  if (error) { msg.textContent = ""; showError("대기열을 불러오지 못했어요: " + error.message); return; }
  clearError();
  const before = scanned.length;
  (data || []).forEach(r => addBarcode(r.barcode));
  const added = scanned.length - before;
  msg.textContent = !data.length ? "대기열이 비어 있어요."
    : added ? `대기열 ${data.length}장 중 ${added}장을 목록에 담았어요.` : `대기열 ${data.length}장은 이미 목록에 있어요.`;
});

document.getElementById("print-btn").addEventListener("click", () => {
  if (scanned.length === 0) return;
  const url = "labels.html?barcodes=" + encodeURIComponent(scanned.join(","));
  window.open(url, "_blank");
});

setTimeout(() => bi.focus(), 200);
