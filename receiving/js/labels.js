// ZPL 상수 — 온라인(300dpi GT800-3005P0-100) / 물류(203dpi GT800)
// 세로 스택형 레이아웃: 상품명 → 가격 → 바코드 → 바코드번호
// NAME_H: GFA 캔버스 높이(1줄), NAME_H2: 2줄일 때 높이
// GAP1/2/3: 블록 사이 여백. Y 좌표는 콘텐츠 총 높이 기준으로 매 아이템마다 동적으로 계산해 라벨 내에서 중앙정렬한다.
const ZPL_CONFIGS = {
  online:    { LW: 472, LH: 354, NAME_H: 48, NAME_H2: 90, GAP1: 8, GAP2: 10, GAP3: 8, H_BC: 130, F_PRICE: 72, F_BCNUM: 34, BC_BY: 3 },
  logistics: { LW: 320, LH: 240, NAME_H: 33, NAME_H2: 61, GAP1: 5, GAP2:  7, GAP3: 5, H_BC:  88, F_PRICE: 49, F_BCNUM: 23, BC_BY: 2 },
};
let ZPL = ZPL_CONFIGS.online;

// 온라인 입고라도 옷이 아닌 잡화는 카테고리에 "온" 접두사를 붙이지 않음
const NON_CLOTHING_CATEGORIES = new Set(["신발", "가방", "패션잡화", "ETC", "패브릭", "모자"]);

// ZPL ^FD 필드에 ^ 문자가 들어가면 명령어로 해석되므로 제거
function sanitizeZpl(s) {
  return String(s == null ? "" : s).replace(/\^/g, "");
}

// Canvas 픽셀 → ZPL ^GFA hex
function _pixelsToGFA(canvas, W, H) {
  const pixels = canvas.getContext("2d").getImageData(0, 0, W, H).data;
  const bpr = Math.ceil(W / 8);
  let hex = "";
  for (let y = 0; y < H; y++) {
    const row = new Uint8Array(bpr);
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const lum = 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      if (lum < 128) row[x >> 3] |= 0x80 >> (x & 7);
    }
    hex += Array.from(row).map(b => b.toString(16).padStart(2, "0").toUpperCase()).join("");
  }
  return `^GFA,${bpr * H},${bpr * H},${bpr},${hex}`;
}

// Canvas로 텍스트를 비트맵 → ZPL ^GFA 변환
// 반환: { gfa: "^GFA,...", h: 실제사용높이 }
function nameToGFA(text, boxH = ZPL.NAME_H, boxH2 = ZPL.NAME_H2) {
  const W = ZPL.LW;
  const BASE_FONT = Math.round(boxH * 0.78);
  const MIN_FONT  = Math.round(BASE_FONT * 0.55);
  const FONT_FAM  = '"Apple SD Gothic Neo", "Noto Sans KR", "Malgun Gothic", sans-serif';

  // 1줄 폰트 자동 축소
  const c1 = document.createElement("canvas");
  c1.width = W; c1.height = boxH;
  const ctx1 = c1.getContext("2d");

  let fontSize = BASE_FONT;
  ctx1.font = `700 ${fontSize}px ${FONT_FAM}`;
  while (ctx1.measureText(text).width > W - 8 && fontSize > MIN_FONT) {
    fontSize -= 1;
    ctx1.font = `700 ${fontSize}px ${FONT_FAM}`;
  }

  // 축소해도 넘치면 2줄 분리
  if (ctx1.measureText(text).width > W - 8) {
    const words = text.split(" ");
    let best = Math.ceil(words.length / 2);
    // 공백 기준 가운데 나누기
    let line1 = words.slice(0, best).join(" ");
    let line2 = words.slice(best).join(" ");
    if (!line2) { line1 = text.slice(0, Math.ceil(text.length / 2)); line2 = text.slice(Math.ceil(text.length / 2)); }

    const H2 = boxH2;
    const lineH = Math.floor(H2 / 2);
    const c2 = document.createElement("canvas");
    c2.width = W; c2.height = H2;
    const ctx2 = c2.getContext("2d");
    ctx2.fillStyle = "#fff"; ctx2.fillRect(0, 0, W, H2);
    ctx2.fillStyle = "#000";

    let fs2 = BASE_FONT;
    ctx2.font = `700 ${fs2}px ${FONT_FAM}`;
    const maxW = Math.max(ctx2.measureText(line1).width, ctx2.measureText(line2).width);
    if (maxW > W - 8) {
      fs2 = Math.max(MIN_FONT, Math.floor(fs2 * (W - 8) / maxW));
    }
    ctx2.font = `700 ${fs2}px ${FONT_FAM}`;
    ctx2.textAlign = "center"; ctx2.textBaseline = "middle";
    ctx2.fillText(line1, W / 2, lineH * 0.5);
    ctx2.fillText(line2, W / 2, lineH * 1.5);
    return { gfa: _pixelsToGFA(c2, W, H2), h: H2 };
  }

  ctx1.fillStyle = "#fff"; ctx1.fillRect(0, 0, W, boxH);
  ctx1.fillStyle = "#000";
  ctx1.font = `700 ${fontSize}px ${FONT_FAM}`;
  ctx1.textAlign = "center"; ctx1.textBaseline = "middle";
  ctx1.fillText(text, W / 2, boxH / 2);
  return { gfa: _pixelsToGFA(c1, W, boxH), h: boxH };
}


// Code 128 바코드 너비 추정 → 라벨 중앙 정렬 X 계산
function calcBarcodeX(barcodeStr) {
  if (!barcodeStr) return 0;
  // Code 128C로 인코딩 가능한 연속 숫자 쌍 수 계산
  let cPairs = 0, i = 0;
  while (i < barcodeStr.length - 1) {
    if (/\d/.test(barcodeStr[i]) && /\d/.test(barcodeStr[i + 1])) { cPairs++; i += 2; }
    else { i++; }
  }
  const bChars = barcodeStr.length - cPairs * 2;
  const switches = (cPairs > 0 && bChars > 0) ? 11 : 0; // code set 전환 오버헤드
  // start(11) + data + check(11) + stop(13) = 35 fixed
  const modules = 35 + cPairs * 11 + bChars * 11 + switches;
  return Math.max(0, Math.floor((ZPL.LW - modules * ZPL.BC_BY) / 2));
}

// displayName 계산 (세션/재출력 경로 공통)
function buildDisplayName(brand, category, productName, barcode) {
  brand = (brand || "").trim();
  category = (category || "").trim();
  productName = (productName || "").trim();
  if (brand && category) return `${brand} ${category}`;
  if (productName) return productName;
  if (category) return category;
  return barcode || "";
}

function generateZpl(items) {
  const lines = [];
  for (const item of items) {
    if (item.isSeparator) {
      const hnum = sanitizeZpl(item.hangerNumber);
      if (item.operatorName) {
        const label = `${item.prefix ? sanitizeZpl(item.prefix) + " · " : ""}${sanitizeZpl(item.operatorName)} · ${hnum}번 행거`;
        const boxH = Math.round(ZPL.LH * 0.5);
        const { gfa, h } = nameToGFA(label, boxH, boxH);
        const y = Math.max(0, Math.floor((ZPL.LH - h) / 2));
        lines.push("^XA", "^LH0,0", `^PW${ZPL.LW}`, `^LL${ZPL.LH}`, `^FO0,${y}${gfa}^FS`, "^XZ", "");
      } else {
        const numFont = String(hnum).length === 1 ? 200 : 160;
        lines.push(
          "^XA", "^LH0,0",
          `^PW${ZPL.LW}`, `^LL${ZPL.LH}`,
          `^FO0,90^A0N,${numFont},${numFont}^FB${ZPL.LW},1,0,C^FD${hnum}^FS`,
          "^XZ", ""
        );
      }
      continue;
    }

    const barcode = sanitizeZpl(item.barcode);
    // price가 NaN이면 0원으로 fallback
    const price = isFinite(Number(item.price)) ? Number(item.price) : 0;
    const priceStr = sanitizeZpl(price.toLocaleString("ko-KR"));
    const displayName = (item.displayName || "").trim();
    const hasKorean = /[ㄱ-ㅎ가-힣]/.test(displayName);

    // 상품명 비트맵/텍스트 준비 (실제 사용 높이 nameH만 먼저 계산, Y좌표는 아래서 일괄 계산)
    let nameGfa = null, nameAscii = null, nameH = 0;
    if (displayName) {
      if (hasKorean) {
        const { gfa, h } = nameToGFA(displayName);
        nameGfa = gfa;
        nameH = h;
      } else {
        nameAscii = sanitizeZpl(displayName.replace(/[^\x00-\x7F]/g, "")).slice(0, 29);
        nameH = ZPL.NAME_H;
      }
    }

    // 콘텐츠 총 높이 기준으로 Y좌표를 동적 계산해 라벨(LH) 내에서 상하 중앙정렬
    const totalH = nameH + ZPL.GAP1 + ZPL.F_PRICE + ZPL.GAP2 + ZPL.H_BC + ZPL.GAP3 + ZPL.F_BCNUM;
    const yName  = Math.max(0, Math.floor((ZPL.LH - totalH) / 2));
    const yPrice = yName  + nameH        + ZPL.GAP1;
    const yBc    = yPrice + ZPL.F_PRICE  + ZPL.GAP2;
    const yBcNum = yBc    + ZPL.H_BC     + ZPL.GAP3;

    const nameCmd = nameGfa
      ? `^FO0,${yName}${nameGfa}^FS`
      : nameAscii
        ? `^FO0,${yName}^A0N,${ZPL.NAME_H},${ZPL.NAME_H}^FB${ZPL.LW},1,0,C^FD${nameAscii}^FS`
        : "";

    // ^BCN은 ^FB 중앙정렬 미지원 → 모듈 수 기반으로 X 직접 계산
    const bcLines = barcode
      ? [
          `^FO${calcBarcodeX(barcode)},${yBc}^BY${ZPL.BC_BY}^BCN,${ZPL.H_BC},N,N,N,A^FD${barcode}^FS`,
          `^FO0,${yBcNum}^A0N,${ZPL.F_BCNUM},${ZPL.F_BCNUM}^FB${ZPL.LW},1,0,C^FD${barcode}^FS`,
        ]
      : [];

    lines.push(
      "^XA", "^LH0,0",
      `^PW${ZPL.LW}`, `^LL${ZPL.LH}`,
      ...(nameCmd ? [nameCmd] : []),
      `^FO0,${yPrice}^A0N,${ZPL.F_PRICE},${ZPL.F_PRICE}^FB${ZPL.LW},1,0,C^FD${priceStr}^FS`,
      ...bcLines,
      "^XZ", ""
    );
  }
  return lines.join("\n");
}

// 세션 기반 아이템 목록 구성
async function buildItemsFromSession(sessionId) {
  const [{ data: sessRows, error: sessErr }, { data: hangerRows, error: hangerErr }] = await Promise.all([
    sb.from("inventory_sessions").select("*").eq("id", sessionId),
    sb.from("inventory_hangers").select("*").eq("session_id", sessionId).order("hanger_number"),
  ]);
  if (sessErr) throw new Error(sessErr.message);
  if (hangerErr) throw new Error(hangerErr.message);
  if (!sessRows || !sessRows.length) throw new Error("세션을 찾을 수 없습니다.");
  const sess = sessRows[0];
  const hangers = hangerRows || [];
  // hanger_number는 TEXT 컬럼이라 DB 정렬은 사전식("1","10","11","2"...)이 됨 — 숫자 자연 정렬로 보정
  hangers.sort((a, b) => String(a.hanger_number).localeCompare(String(b.hanger_number), "ko", { numeric: true }));

  // N+1 방지: 모든 hanger_id를 한 번에 조회
  const hangerIds = hangers.map(h => h.id);
  const allItems = [];
  if (hangerIds.length) {
    const { data: invItems, error: itemErr } = await sb
      .from("inventory_items")
      .select("hanger_id,barcode,price,brand,category,product_name,order_index")
      .in("hanger_id", hangerIds)
      .order("order_index");
    if (itemErr) throw new Error(itemErr.message);

    // hanger_id별 order_index 순 그룹핑
    const itemsByHanger = {};
    for (const it of (invItems || [])) {
      (itemsByHanger[it.hanger_id] ??= []).push(it);
    }

    // 행거 순서(hanger_number 오름차순) 그대로 순회 → 바코드 자동할당이 행거 순서를 따르도록 보장
    for (const hanger of hangers) {
      for (const it of (itemsByHanger[hanger.id] || [])) {
        let category = it.category || "";
        // 온라인 입고라도 옷이 아닌 잡화는 카테고리에 "온" 접두사를 붙이지 않음
        if (sess.location === "온라인" && !NON_CLOTHING_CATEGORIES.has(category)) category = "온" + category;
        allItems.push({
          price: isFinite(Number(it.price)) ? Number(it.price) : 0,
          brand: it.brand || "",
          category,
          product_name: it.product_name || "",
          barcode: it.barcode || "",
          hangerNumber: hanger.hanger_number,
          hangerId: hanger.id,
          operatorName: hanger.submitted_by || sess.created_by || "담당자 미입력",
          barcodePrefix: sess.barcode_prefix,
          printedAt: hanger.printed_at || null,
          kioskExportedAt: hanger.kiosk_exported_at || null,
        });
      }
    }
  }

  // 바코드가 하나라도 배정 안 된 상태 = 입고처리 크론이 아직 다 안 돌았음(진행 중 포함).
  // 예전엔 여기서 클라이언트가 순서를 추측해서 임시 바코드를 붙였는데,
  // 이 추측 순서가 실제 크론의 배정 순서와 달라질 수 있어(예: 행거번호 "4-1" 같은
  // 비숫자 케이스 정렬 차이) 라벨이 엉뚱한 바코드로 인쇄되는 사고가 있었음.
  // 그래서 추측 대신 명시적으로 막고 재시도를 유도한다.
  if (allItems.some(it => !it.barcode)) {
    throw new Error("바코드가 아직 배정되지 않았습니다. 입고처리(약 2분 주기)가 끝난 후 다시 시도하세요.");
  }

  allItems.forEach(it => {
    it.displayName = buildDisplayName(it.brand, it.category, it.product_name || "", it.barcode);
  });

  // 담당자별로 묶어서 정렬 — 각자 본인이 작업한 행거 라벨만 모아서 붙이러 갈 수 있도록
  const { items: result } = groupItemsForPrint(allItems, { includePrefix: false });
  return { items: result, sess };
}

// 아이템 목록을 담당자(operatorName) → 행거번호 순으로 묶어 구분지와 함께 재구성.
// includePrefix: true면 접두사까지 그룹 키에 포함 (여러 세션을 합칠 때, 같은 사람이 같은
// 행거번호를 다른 접두사 세션에서 맡아도 서로 섞이지 않도록 함)
function groupItemsForPrint(items, { includePrefix = false } = {}) {
  const groups = new Map();
  for (const it of items) {
    const prefix = it.barcodePrefix || "";
    const key = includePrefix
      ? `${prefix}__${it.operatorName}__${it.hangerNumber}`
      : `${it.operatorName}__${it.hangerNumber}`;
    if (!groups.has(key)) {
      groups.set(key, { prefix, operatorName: it.operatorName, hangerNumber: it.hangerNumber, items: [], hangerIds: new Set() });
    }
    const g = groups.get(key);
    g.items.push(it);
    if (it.hangerId) g.hangerIds.add(it.hangerId);
  }

  const sortedGroups = [...groups.values()].sort((a, b) => {
    if (includePrefix) {
      const byPrefix = a.prefix.localeCompare(b.prefix, "ko");
      if (byPrefix !== 0) return byPrefix;
    }
    const byName = a.operatorName.localeCompare(b.operatorName, "ko");
    if (byName !== 0) return byName;
    return String(a.hangerNumber).localeCompare(String(b.hangerNumber), "ko", { numeric: true });
  });

  const result = [];
  const hangerIds = new Set();
  for (const g of sortedGroups) {
    if (!g.items.length) continue;
    result.push({
      isSeparator: true,
      prefix: includePrefix ? g.prefix : "",
      operatorName: g.operatorName,
      hangerNumber: g.hangerNumber,
    });
    result.push(...g.items);
    g.hangerIds.forEach(id => hangerIds.add(id));
  }
  return { items: result, hangerIds: [...hangerIds] };
}

// 바코드 목록 기반 아이템 구성
async function buildItemsFromBarcodes(barcodes) {
  const { data: rows, error } = await sb
    .from("inventory_items")
    .select("barcode,price,brand,category,product_name")
    .in("barcode", barcodes);
  if (error) throw new Error(error.message);

  const dbMap = {};
  (rows || []).forEach(r => { if (r.barcode) dbMap[r.barcode.toUpperCase()] = r; });

  const items = [], notFound = [];
  for (const bc of barcodes) {
    const row = dbMap[bc.toUpperCase()];
    if (!row) { notFound.push(bc); continue; }
    items.push({
      barcode: bc,
      price: isFinite(Number(row.price)) ? Number(row.price) : 0,
      displayName: buildDisplayName(row.brand, row.category, row.product_name, bc),
    });
  }
  return { items, notFound };
}

// 로컬(KST) 기준 YYYY-MM-DD
function localDateStr(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// 특정 날짜(KST)에 승인된 모든 세션을 접두사→담당자→행거번호 순으로 그룹핑해 아이템 목록 구성.
// 세션별 바코드 자동할당 로직은 buildItemsFromSession을 그대로 재사용한다.
async function buildItemsFromDaily(dateStr, includePrinted) {
  const { data: sessRows, error: sessErr } = await sb
    .from("inventory_sessions")
    .select("id")
    .eq("session_date", dateStr)
    .in("status", ["approved", "processed"])
    .not("start_barcode_num", "is", null);
  if (sessErr) throw new Error(sessErr.message);
  if (!sessRows || !sessRows.length) return { items: [], hangerIds: [] };

  const sessionResults = await Promise.all(sessRows.map(s => buildItemsFromSession(s.id)));

  const allItems = [];
  for (const r of sessionResults) {
    for (const it of r.items) {
      if (it.isSeparator) continue;
      if (!includePrinted && it.printedAt) continue;
      allItems.push(it);
    }
  }

  return groupItemsForPrint(allItems, { includePrefix: true });
}

async function markHangersPrinted(hangerIds) {
  if (!hangerIds || !hangerIds.length) return;
  await sb.from("inventory_hangers").update({ printed_at: new Date().toISOString() }).in("id", hangerIds);
}

async function markHangersKioskExported(hangerIds) {
  if (!hangerIds || !hangerIds.length) return;
  await sb.from("inventory_hangers").update({ kiosk_exported_at: new Date().toISOString() }).in("id", hangerIds);
}

// HTML 라벨 미리보기 렌더 (SVG id는 index 기반으로 CSS selector 충돌 방지)
function renderPreview(items) {
  const grid = document.getElementById("label-grid");
  grid.innerHTML = items.map((item, idx) => {
    if (item.isSeparator) {
      if (item.operatorName) {
        const text = `${item.prefix ? item.prefix + " · " : ""}${item.operatorName} · ${item.hangerNumber}번 행거`;
        return `<div class="label-separator"><div class="sep-num sep-num-op">${escapeHtml(text)}</div></div>`;
      }
      return `<div class="label-separator"><div class="sep-num">${escapeHtml(String(item.hangerNumber))}</div></div>`;
    }
    return `
      <div class="label">
        <div class="label-name">${escapeHtml(item.displayName || "")}</div>
        <div class="label-price-wrap">
          <div class="label-price">${(isFinite(Number(item.price)) ? Number(item.price) : 0).toLocaleString("ko-KR")}</div>
        </div>
        <div class="label-bottom">
          <div class="label-barcode"><svg id="bc-idx-${idx}"></svg></div>
          <div class="label-barcode-num">${escapeHtml(item.barcode || "")}</div>
        </div>
      </div>`;
  }).join("");

  items.forEach((item, idx) => {
    if (item.isSeparator || !item.barcode) return;
    try {
      JsBarcode(`#bc-idx-${idx}`, item.barcode, {
        format: "CODE128", width: 1.2, height: 28, displayValue: false, margin: 1,
      });
    } catch (e) { console.warn("바코드 렌더 실패:", item.barcode, e); }
  });
}

function downloadZpl(zplText, filename) {
  const blob = new Blob([zplText], { type: "text/plain" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 100);
}

async function zebraPrint(zplText, totalCount, onSuccess) {
  const btn = document.getElementById("zebra-btn");
  btn.disabled = true;
  btn.textContent = "⏳ 프린터 연결 중…";

  if (typeof BrowserPrint === "undefined") {
    await appAlert("❌ BrowserPrint SDK 로드 실패");
    btn.textContent = "🦓 Zebra 직접 출력"; btn.disabled = false;
    return;
  }

  BrowserPrint.getDefaultDevice("printer",
    printer => {
      if (!printer) {
        appAlert("❌ 연결된 Zebra 프린터 없음\nUSB 케이블 및 전원을 확인하세요.");
        btn.textContent = "🦓 Zebra 직접 출력"; btn.disabled = false;
        return;
      }
      btn.textContent = `⏳ 전송 중… (${totalCount}장)`;
      printer.send(zplText,
        () => {
          btn.textContent = "✓ 출력 완료!";
          btn.style.background = "#166534";
          if (typeof onSuccess === "function") onSuccess();
          setTimeout(() => {
            btn.textContent = "🦓 Zebra 직접 출력";
            btn.style.background = "#22c55e";
            btn.disabled = false;
          }, 3000);
        },
        err => {
          appAlert("❌ 전송 실패: " + (err || "알 수 없는 오류"));
          btn.textContent = "🦓 Zebra 직접 출력"; btn.disabled = false;
        }
      );
    },
    err => {
      appAlert("❌ Browser Print 연결 실패\nBrowser Print 앱이 실행 중인지 확인하세요.\n오류: " + (err || "unknown"));
      btn.textContent = "🦓 Zebra 직접 출력"; btn.disabled = false;
    }
  );
}

// ── 진입점 ──────────────────────────────────────────────────────────────────
async function main() {
  const params = new URLSearchParams(location.search);
  const sessionId = params.get("session_id");
  const barcodesParam = params.get("barcodes");
  const isDaily = params.get("daily") === "1";

  const zplBtn = document.getElementById("zpl-btn");
  const zebraBtn = document.getElementById("zebra-btn");
  let items, notFound = [], sess = null, zplFilename = "labels.zpl", hangerIds = [];

  if (isDaily) {
    document.getElementById("daily-controls").style.display = "flex";
    const dateInput = document.getElementById("daily-date");
    dateInput.value = params.get("date") || localDateStr();

    async function loadDaily() {
      const dateStr = dateInput.value || localDateStr();
      const includePrinted = document.getElementById("daily-include-printed").checked;
      document.getElementById("header-title").textContent = `🖨 오늘 입고 일괄출력 — ${dateStr}`;
      document.getElementById("header-sub").textContent = "불러오는 중...";
      document.getElementById("not-found-box").style.display = "none";
      try {
        const result = await buildItemsFromDaily(dateStr, includePrinted);
        items = result.items; hangerIds = result.hangerIds;
        zplFilename = `labels_daily_${dateStr}.zpl`;
        const labelCount = items.filter(it => !it.isSeparator).length;
        document.getElementById("header-sub").textContent = labelCount
          ? `총 ${labelCount}장 (미출력 기준${includePrinted ? " · 출력완료건 포함" : ""})`
          : "출력할 입고 건이 없습니다.";
        renderPreview(items);
        bindDailyPrintButtons();
      } catch (e) {
        document.getElementById("header-sub").textContent = "오류: " + e.message;
      }
    }
    function bindDailyPrintButtons() {
      const zplText = generateZpl(items);
      const labelCount = items.filter(it => !it.isSeparator).length;
      zplBtn.onclick = () => { downloadZpl(zplText, zplFilename); markHangersPrinted(hangerIds); };
      zebraBtn.onclick = () => zebraPrint(zplText, labelCount, () => markHangersPrinted(hangerIds));
    }
    document.getElementById("daily-reload-btn").onclick = loadDaily;
    document.getElementById("daily-include-printed").onchange = loadDaily;
    dateInput.onchange = loadDaily;
    document.getElementById("daily-kiosk-btn").onclick = async () => {
      const includeKioskExported = document.getElementById("daily-include-kiosk-exported").checked;
      const labelItems = items.filter(it => !it.isSeparator && (includeKioskExported || !it.kioskExportedAt));
      if (!labelItems.length) { appAlert("다운로드할 항목이 없습니다. (이미 다운로드한 건만 있다면 '이미 다운로드한 건 포함' 체크)"); return; }
      const ws = XLSX.utils.aoa_to_sheet([
        ["상품명", "바코드", "판매단가"],
        ...labelItems.map(it => [it.displayName || "", it.barcode, it.price]),
      ]);
      const wb = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(wb, ws, "Sheet1");
      XLSX.writeFile(wb, `kiosk_upload_${dateInput.value || localDateStr()}.xlsx`);

      const kioskHangerIds = [...new Set(labelItems.map(it => it.hangerId).filter(Boolean))];
      await markHangersKioskExported(kioskHangerIds);
      const now = new Date().toISOString();
      labelItems.forEach(it => { it.kioskExportedAt = now; });
    };

    document.querySelectorAll(".team-btn").forEach(btn => {
      btn.onclick = () => {
        document.querySelectorAll(".team-btn").forEach(b => b.classList.remove("active"));
        btn.classList.add("active");
        ZPL = ZPL_CONFIGS[btn.dataset.team];
        renderPreview(items);
        bindDailyPrintButtons();
      };
    });

    await loadDaily();
    return;
  }

  try {
    if (sessionId) {
      ({ items, sess } = await buildItemsFromSession(sessionId));
      hangerIds = [...new Set(items.filter(it => !it.isSeparator && it.hangerId).map(it => it.hangerId))];
      const date = sess.session_date || new Date().toISOString().slice(0, 10);
      zplFilename = `labels_${date}_${sess.barcode_prefix}.zpl`;
      const labelCount = items.filter(it => !it.isSeparator).length;
      document.getElementById("header-title").textContent = `🖨 라벨 출력 — ${date}`;
      document.getElementById("header-sub").textContent =
        `총 ${labelCount}장` +
        (sess.start_barcode_num
          ? ` · ${sess.barcode_prefix}${sess.start_barcode_num} ~ ${sess.barcode_prefix}${sess.start_barcode_num + labelCount - 1}`
          : "");
    } else if (barcodesParam) {
      const barcodes = barcodesParam.split(",").map(s => s.trim().toUpperCase()).filter(Boolean);
      ({ items, notFound } = await buildItemsFromBarcodes(barcodes));
      document.getElementById("header-title").textContent = "🖨 라벨 재출력";
      document.getElementById("header-sub").textContent = `총 ${items.length}장`;
    } else {
      document.getElementById("header-title").textContent = "잘못된 접근";
      zplBtn.disabled = true; zebraBtn.disabled = true;
      return;
    }
  } catch (e) {
    document.getElementById("header-title").textContent = "오류";
    document.getElementById("header-sub").textContent = e.message;
    zplBtn.disabled = true; zebraBtn.disabled = true;
    return;
  }

  if (notFound.length) {
    const box = document.getElementById("not-found-box");
    box.style.display = "block";
    document.getElementById("not-found-title").textContent =
      `⚠ DB에서 찾지 못한 바코드 ${notFound.length}개`;
    document.getElementById("not-found-list").textContent = notFound.join(", ");
  }

  renderPreview(items);

  const labelItems = items.filter(it => !it.isSeparator);

  function bindPrintButtons() {
    const zplText = generateZpl(items);
    zplBtn.onclick = () => { downloadZpl(zplText, zplFilename); markHangersPrinted(hangerIds); };
    zebraBtn.onclick = () => zebraPrint(zplText, labelItems.length, () => markHangersPrinted(hangerIds));
  }

  document.querySelectorAll(".team-btn").forEach(btn => {
    btn.onclick = () => {
      document.querySelectorAll(".team-btn").forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      ZPL = ZPL_CONFIGS[btn.dataset.team];
      bindPrintButtons();
    };
  });

  bindPrintButtons();
}

main();
