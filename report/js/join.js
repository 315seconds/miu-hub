// join.js — raw_builder 로직 이관
// 영수증(트랜잭션) + 카드 조인, 바코드 매칭, 두 달 입고 합치기

const QRPAY_METHODS = new Set(['알리페이', '위챗페이']);

// ─── 두 달 입고 합치기 (build_ingo) ────────────────────────────
function mergeIngo(mainItems, prevItems) {
  if (!prevItems || prevItems.length === 0) {
    return { items: mainItems, soaked: 0 };
  }
  const mainBc = new Set(mainItems.map(i => i.바코드));
  const onlyPrev = prevItems.filter(i => !mainBc.has(i.바코드));
  return { items: [...mainItems, ...onlyPrev], soaked: onlyPrev.length };
}

// ─── 바코드 → 단가 맵 (build_price_map) ────────────────────────
// 동일 바코드에 여러 입고 있으면 최근 입고일 기준
function buildPriceMap(ingoItems) {
  const map = new Map();
  const sorted = [...ingoItems].sort((a, b) => {
    const da = a.입고일 ? a.입고일.getTime() : 0;
    const db = b.입고일 ? b.입고일.getTime() : 0;
    return db - da;  // 최근 먼저
  });
  for (const item of sorted) {
    if (!map.has(item.바코드) && item.금액 != null) {
      map.set(item.바코드, item.금액);
    }
  }
  return map;
}

// ─── 바코드 → 소분류 맵 ────────────────────────────────────────
function buildCategoryMap(ingoItems) {
  const map = new Map();
  for (const item of ingoItems) {
    if (item.바코드 && !map.has(item.바코드)) {
      map.set(item.바코드, item.소분류);
    }
  }
  return map;
}

// ─── 아이템명 → 바코드 매칭 (build_resolve_fn) ────────────────
function buildResolveFn(ingoItems) {
  // 상품명별로 그룹핑
  const nameToItems = new Map();
  for (const item of ingoItems) {
    const name = item.상품명;
    if (!name) continue;
    if (!nameToItems.has(name)) nameToItems.set(name, []);
    nameToItems.get(name).push({ amount: item.금액, barcode: item.바코드 });
  }

  const cache = new Map();

  function keywordSearch(text) {
    const words = text.split(/\s+/).filter(w => w);
    if (words.length === 0) return [];
    const matches = [];
    for (const [name, items] of nameToItems) {
      if (words.every(w => name.includes(w))) {
        matches.push(...items);
      }
    }
    return matches;
  }

  function pick(matches, txAmount, nItems) {
    if (nItems === 1) {
      const exact = matches.filter(m => m.amount === txAmount);
      if (exact.length === 1) return String(exact[0].barcode);
    }
    return String(matches[0].barcode);
  }

  return function resolve(raw, txAmount, nItems) {
    const key = String(raw || '').trim();
    if (cache.has(key)) {
      const c = cache.get(key);
      return Array.isArray(c) ? pick(c, txAmount, nItems) : c;
    }
    if (!key || key === 'nan' || key === 'None') return null;

    // 이미 바코드 형식이면 그대로 (영문/숫자/하이픈만)
    if (/^[A-Za-z0-9-]+$/.test(key)) {
      cache.set(key, key);
      return key;
    }
    // 알파숫자 접두어만 추출 (예: "C123 나이키 티" → "C123")
    if (/^[A-Za-z0-9]/.test(key)) {
      const m = key.match(/^([A-Za-z0-9]+)/);
      if (m) {
        const r = m[1];
        cache.set(key, r);
        return r;
      }
    }
    // 상품명 정확 매칭
    let matches = nameToItems.get(key);
    if (!matches || matches.length === 0) {
      matches = keywordSearch(key);
    }
    if (matches.length === 0) {
      const r = `[미매칭]${key}`;
      cache.set(key, r);
      return r;
    }
    if (matches.length === 1) {
      const r = String(matches[0].barcode);
      cache.set(key, r);
      return r;
    }
    cache.set(key, matches);
    return pick(matches, txAmount, nItems);
  };
}

// ─── 키오스크 하나의 영수증 + 카드 조인 ────────────────────────
// 반환: [{ 거래일시, 지점명, 승인금액, 카드발급사명, items: [바코드...] }, ...]
function joinReceiptCard(receipts, cards, storeLabel) {
  // 카드 인덱스: (날짜, 전표번호) → 카드 정보
  const cardIdx = new Map();
  for (const c of cards) {
    cardIdx.set(`${c.날짜}|${c.전표번호}`, c);
  }

  const joined = [];
  const qrpayRecs = [];

  for (const r of receipts) {
    const key = `${r.날짜}|${r.전표번호}`;
    const card = cardIdx.get(key);

    // QR결제(알리/위챗) 별도 처리 — 카드파일에 없음
    if (QRPAY_METHODS.has(r.결제수단) && r.결제금액 != null && r.결제금액 > 0) {
      // 거래일시는 정오로 설정 (정확한 시각 정보 없음)
      const dt = new Date(`${r.날짜}T12:00:00`);
      qrpayRecs.push({
        거래일시: dt,
        지점명: storeLabel,
        승인금액: Math.round(r.결제금액),
        카드발급사명: r.결제수단,
        items: r.items,
      });
    } else if (card) {
      joined.push({
        거래일시: card.거래일시,
        지점명: storeLabel,
        승인금액: Math.round(card.승인금액),
        카드발급사명: card.카드발급사명,
        items: r.items,
      });
    }
    // else: 매칭 실패한 영수증 (드묾) — 스킵
  }

  return [...joined, ...qrpayRecs].sort((a, b) => a.거래일시 - b.거래일시);
}

// ─── 전체 키오스크 통합 · 바코드 리졸브 적용 ──────────────────
function combineAllKiosks(kioskDataArr, storeLabel, resolve) {
  const all = [];
  let qrpayCnt = 0;

  for (const { receipts, cards } of kioskDataArr) {
    const merged = joinReceiptCard(receipts, cards, storeLabel);
    qrpayCnt += merged.filter(m => QRPAY_METHODS.has(m.카드발급사명)).length;
    all.push(...merged);
  }

  // 정렬 (전체 통합)
  all.sort((a, b) => a.거래일시 - b.거래일시);

  // 각 트랜잭션의 items[] 바코드 리졸브
  for (const tx of all) {
    const validItems = tx.items.filter(v => v && v !== 'nan');
    const n = validItems.length;
    tx.resolvedItems = validItems.map(bc => resolve(bc, tx.승인금액, n)).filter(v => v != null);
  }

  return { transactions: all, qrpayCnt };
}
