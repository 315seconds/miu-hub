// xlsx-parse.js — SheetJS 기반 3종 파서
// (원본 popup_report의 raw_builder.py · app.py 로직 이관)

// ─── XLSX 유틸 ─────────────────────────────────────────────────
async function readXlsx(file) {
  const buf = await file.arrayBuffer();
  return XLSX.read(buf, { type: 'array', cellDates: true });
}

function sheetToRows(sheet) {
  // 2D 배열, null 채움
  return XLSX.utils.sheet_to_json(sheet, { header: 1, defval: null, raw: false });
}

function firstSheetRows(wb) {
  const name = wb.SheetNames[0];
  return sheetToRows(wb.Sheets[name]);
}

// 숫자 판별 ("3", "3.0", 3 모두 true, "abc" false)
function isNumeric(v) {
  if (v == null) return false;
  const s = String(v).trim();
  if (s === '') return false;
  return /^-?\d+(\.\d+)?$/.test(s);
}

// ─── 영수증 파서 (parse_receipt in Python) ────────────────────
function detectColPositions(rows) {
  let slipCol = 6, barcodeCol = 5;
  for (let i = 1; i < Math.min(5, rows.length); i++) {
    const row = rows[i] || [];
    const vals = row.filter(v => v != null).map(v => String(v).trim());
    if (vals.includes('전표 번호') || vals.includes('전표번호')) {
      // slip_col: "전표"가 포함된 셀 위치
      for (let ci = 0; ci < row.length; ci++) {
        if (row[ci] != null && String(row[ci]).includes('전표')) {
          slipCol = ci;
          break;
        }
      }
      // barcode_col: 다음 몇 행에서 첫 아이템 행 찾기
      for (let j = i + 1; j < Math.min(i + 10, rows.length); j++) {
        const r = rows[j] || [];
        if (isNumeric(r[1]) && isNumeric(r[2])) {
          barcodeCol = (r[4] != null && String(r[4]).trim() !== '') ? 4 : 5;
          break;
        }
      }
      break;
    }
  }
  return { slipCol, barcodeCol };
}

async function parseReceipt(file, storeLabel) {
  const wb = await readXlsx(file);
  const rows = firstSheetRows(wb);
  const { slipCol, barcodeCol } = detectColPositions(rows);

  const transactions = [];
  let cur = null;
  let items = [];

  const flush = () => {
    if (cur) {
      cur.items = items;
      transactions.push(cur);
    }
    cur = null;
    items = [];
  };

  for (let i = 3; i < rows.length; i++) {
    const row = rows[i] || [];

    // 트랜잭션 시작 행: col0=날짜, col{slipCol}=전표번호(숫자)
    if (row[0] != null && isNumeric(row[slipCol])) {
      flush();
      const dateStr = String(row[0]).trim().slice(0, 10);
      cur = {
        전표번호: parseInt(row[slipCol]),
        날짜: dateStr,
        지점명: storeLabel,
        결제수단: null,
        결제금액: null,
      };
      items = [];
      continue;
    }

    // 아이템 행 or 결제 행 (전제: 현재 트랜잭션 있고 col1이 숫자)
    if (cur && isNumeric(row[1])) {
      if (isNumeric(row[2])) {
        // 아이템 행: col{barcodeCol}이 바코드
        const bc = row[barcodeCol] != null ? String(row[barcodeCol]).trim() : '';
        if (bc && bc !== 'nan') {
          items.push(bc);
        }
      } else if (row[2] != null && cur.결제수단 == null) {
        // 결제 행: col2=결제수단 텍스트, col4=금액
        cur.결제수단 = String(row[2]).trim();
        const amt = row[4] != null ? parseFloat(row[4]) : null;
        cur.결제금액 = (amt != null && !isNaN(amt)) ? amt : null;
      }
    }
  }
  flush();
  return transactions;
}

// ─── 카드 파서 (parse_card in Python) ──────────────────────────
async function parseCard(file) {
  const wb = await readXlsx(file);
  const rows = firstSheetRows(wb);
  const out = [];
  for (const row of rows) {
    if (!row) continue;
    // col2가 숫자 & col10(거래일시)가 있으면 거래 행
    if (isNumeric(row[2]) && row[10] != null) {
      out.push({
        전표번호: parseInt(row[3]),
        날짜: String(row[10]).slice(0, 10),
        거래일시: row[10] instanceof Date ? row[10] : new Date(String(row[10])),
        카드발급사명: row[5] != null ? String(row[5]).trim() : '',
        승인금액: parseFloat(row[6]) || 0,
      });
    }
  }
  return out;
}

// ─── 입고 파서 (load_ingo in Python + app.py parse_excel) ─────
async function parseIngo(file) {
  const wb = await readXlsx(file);
  // 시트명 "입고" 우선, 없으면 첫 시트
  const sheetName = wb.SheetNames.includes('입고') ? '입고' : wb.SheetNames[0];
  const sheet = wb.Sheets[sheetName];
  const rows = sheetToRows(sheet);

  if (rows.length < 2) {
    throw new Error('입고 파일이 비어있어요.');
  }

  // app.py 스키마: C=입고일(2), D=상품명(3), E=금액(4), G=바코드(6), H=소분류(7)
  const items = [];
  for (let i = 1; i < rows.length; i++) {
    const row = rows[i] || [];
    const barcode = row[6] != null ? String(row[6]).trim() : '';
    if (!barcode || barcode === 'nan') continue;

    const amtRaw = row[4];
    const amt = amtRaw != null ? parseFloat(amtRaw) : null;
    let dateVal = row[2];
    if (dateVal && !(dateVal instanceof Date)) {
      const d = new Date(String(dateVal));
      if (!isNaN(d.getTime())) dateVal = d;
    }

    items.push({
      바코드: barcode,
      상품명: row[3] != null ? String(row[3]).trim() : '',
      소분류: row[7] != null ? String(row[7]).trim() : '',
      입고일: dateVal instanceof Date ? dateVal : null,
      금액: (amt != null && !isNaN(amt)) ? amt : null,
    });
  }

  if (items.length === 0) {
    throw new Error('입고 시트에서 유효한 행을 찾지 못했어요. 컬럼 위치를 확인해주세요 (C=입고일, D=상품명, E=금액, G=바코드, H=소분류).');
  }

  return items;
}
