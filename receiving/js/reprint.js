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

document.getElementById("print-btn").addEventListener("click", () => {
  if (scanned.length === 0) return;
  const url = "labels.html?barcodes=" + encodeURIComponent(scanned.join(","));
  window.open(url, "_blank");
});

setTimeout(() => bi.focus(), 200);
