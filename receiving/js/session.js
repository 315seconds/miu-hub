const SESSION_ID = getParam("id");
const STATUS_LABEL = { pending: "대기중", approved: "승인됨", processed: "처리완료" };
let MY_NAME = "";   // 로그인한 계정 이름 (행거 담당자로 자동 기록)
let SOURCES  = [];
let PURCHASE_SRC = new Map();   // 사입 출처 이름 → sources.id (사입 통계 스키마가 없으면 비어 있음)
let BATCHES  = [];               // 사입 차시 목록(전체)

async function load() {
  if (!SESSION_ID) { showError("세션 ID 없음"); return; }
  try {
    const [{ data: sess, error: se }, { data: hangers, error: he }, { data: sources }, { data: psrc }, { data: batches }] = await Promise.all([
      sb.from("inventory_sessions").select("*").eq("id", SESSION_ID).single(),
      sb.from("inventory_hangers").select("*, inventory_items(*)").eq("session_id", SESSION_ID).order("created_at", { ascending: false }),
      sb.from("sources").select("name").eq("is_active", true).order("name"),
      // 사입 차시 선택용. 컬럼·테이블이 아직 없으면 error 로 오고 data 가 null → 차시 선택 없이 기존대로 동작
      sb.from("sources").select("id,name").eq("is_active", true).eq("is_purchase", true),
      sb.from("purchase_batches").select("id,code,round_code,source_id,kind,status").order("received_from", { ascending: false }),
    ]);
    if (se) throw se;
    if (he) throw he;
    MY_NAME = await waitMyName();
    SOURCES  = sources  || [];
    PURCHASE_SRC = new Map((psrc || []).map(s => [s.name, s.id]));
    BATCHES  = batches  || [];

    const total = hangers.reduce((s, h) => s + (h.inventory_items || []).length, 0);
    render({ session: sess, hangers, total });
  } catch (e) {
    showError("세션 로드 실패: " + e.message);
  }
}

function render({ session: sess, hangers, total }) {
  const titleEl = document.getElementById("page-title");
  const badgeEl = document.getElementById("page-badge");
  if (titleEl) titleEl.textContent = sess.session_date;
  if (badgeEl) badgeEl.innerHTML = `<span class="badge badge-${escapeHtml(sess.status)}">${STATUS_LABEL[sess.status] || sess.status}</span>`;

  const c = document.getElementById("content");
  let html = `
    <div class="card text-sm" style="margin-bottom:16px">
      <div class="flex" style="gap:16px; flex-wrap:wrap">
        <span class="muted">접두사: <strong style="color:var(--fg-primary)">${escapeHtml(sess.barcode_prefix)}</strong></span>
        <span class="muted">위치: <strong style="color:var(--fg-primary)">${escapeHtml(sess.location || "")}</strong></span>
        ${sess.location === "온라인" ? '<span class="tag-online">온라인</span>' : ""}
        ${sess.created_by ? `<span class="muted">개설: ${escapeHtml(sess.created_by)}</span>` : ""}
      </div>
      ${sess.start_barcode_num ? `
      <div class="mt8 muted">
        바코드: <strong style="color:var(--brand-primary)" class="mono">
          ${escapeHtml(sess.barcode_prefix)}${sess.start_barcode_num}
          ~ ${escapeHtml(sess.barcode_prefix)}${String(parseInt(sess.start_barcode_num, 10) + total - 1).padStart(String(sess.start_barcode_num).length, "0")}
        </strong> (총 ${total}벌)
      </div>` : ""}
    </div>
    <div class="sum-bar">
      <span class="muted text-sm">행거 ${hangers.length}개 · 총 ${total}벌</span>
    </div>
  `;

  if (sess.status === "pending") {
    html += `
      <div id="add-hanger" class="card mt16">
        <h2>행거 추가</h2>
        <div class="form-group">
          <label>행거 번호</label>
          <input type="text" id="hanger-number" placeholder="1, 2, A1 ..." autofocus>
        </div>
        <div class="form-group mt8">
          <label>담당자</label>
          <div class="text-sm">${MY_NAME
            ? `<strong>${escapeHtml(MY_NAME)}</strong> <span class="muted">(로그인한 계정으로 자동 기록돼요)</span>`
            : `<span class="danger">계정에 이름이 설정돼 있지 않아요. 관리자에게 요청해 주세요.</span>`}</div>
        </div>
        <div class="form-group mt8">
          <label>출처</label>
          <select id="source-select">
            <option value="">거래처를 선택하세요</option>
            ${SOURCES.map(s => `<option value="${escapeHtml(s.name)}">${escapeHtml(s.name)}</option>`).join("")}
          </select>
        </div>
        <div class="form-group mt8" id="batch-group" style="display:none">
          <label>차시</label>
          <select id="batch-select"></select>
        </div>
        <button id="add-hanger-btn" class="btn btn-success btn-block">행거 추가 →</button>
      </div>`;
  }

  if (hangers.length > 0) {
    const myName = MY_NAME;
    html += hangers.map(h => {
      const items = h.inventory_items || [];
      const isMine = !h.submitted_by || h.submitted_by === myName;
      const cats = [...new Set(items.map(it => it.category).filter(Boolean))];
      return `
        <div class="card">
          <div class="flex" style="align-items:center; margin-bottom:8px">
            <span style="font-size:17px; font-weight:700; margin-right:8px">행거 ${escapeHtml(h.hanger_number)}</span>
            <span style="font-weight:600; color:var(--fg-secondary)">${cats.length ? escapeHtml(cats.join(" · ")) : '<span class="muted">카테고리 미정</span>'}</span>
            ${h.source ? `<span style="margin-left:8px;padding:2px 8px;font-size:11px;border-radius:6px;background:var(--miu-surface-soft);color:var(--miu-body)">${escapeHtml(h.source)}</span>` : ""}
            ${h.purchase_batch_id ? `<span style="margin-left:6px;padding:2px 8px;font-size:11px;border-radius:6px;background:var(--miu-surface-soft);color:var(--miu-body)">${escapeHtml(batchTag(h))}</span>` : ""}
            ${sess.location === "온라인" ? '<span class="tag-online" style="margin-left:8px">온라인</span>' : ""}
            <span class="muted text-sm" style="margin-left:auto">${items.length}벌</span>
            ${sess.status === "pending" && isMine ? `
              <a href="hanger.html?id=${encodeURIComponent(h.id)}" class="btn btn-outline btn-sm" style="margin-left:8px">편집</a>
              <button class="del-hanger-btn btn btn-sm" data-id="${escapeHtml(h.id)}" data-num="${escapeHtml(h.hanger_number)}"
                style="margin-left:6px; background:none; border:1px solid #ef4444; border-radius:6px; color:#ef4444; font-size:12px; padding:4px 8px; cursor:pointer">삭제</button>
            ` : sess.status === "pending" ? `
              <span class="muted text-xs" style="margin-left:8px">🔒 ${escapeHtml(h.submitted_by)}만 편집 가능</span>
            ` : ""}
          </div>
          ${items.length > 0 ? `
          <div style="padding-left:4px">
            ${items.map((item, i) => `
              <div class="item-row">
                <span class="item-num">${i + 1}</span>
                <div class="item-info">
                  <div class="item-price">₩${(item.price || 0).toLocaleString()}</div>
                  ${item.brand ? `<div class="item-brand">${escapeHtml(item.brand)}</div>` : ""}
                  ${item.barcode ? `<div class="text-xs muted">${escapeHtml(item.barcode)}</div>` : ""}
                </div>
              </div>`).join("")}
          </div>` : '<div class="text-sm muted">아이템 없음</div>'}
          ${h.submitted_at ? `<div class="text-xs muted mt8">✓ 제출됨${h.submitted_by ? " · " + escapeHtml(h.submitted_by) : ""}</div>` : ""}
        </div>`;
    }).join("");
  } else {
    html += '<div class="empty">아직 행거가 없습니다</div>';
  }

  c.innerHTML = html;
  document.getElementById("add-hanger-btn")?.addEventListener("click", addHanger);
  document.getElementById("source-select")?.addEventListener("change", updateBatchSelect);
  c.querySelectorAll(".del-hanger-btn").forEach(btn => {
    btn.addEventListener("click", () => deleteHanger(btn.dataset.id, btn.dataset.num, btn));
  });
}

async function deleteHanger(id, num, btn) {
  if (!await appConfirm(`행거 ${num}을(를) 삭제하시겠습니까?\n행거 내 아이템도 모두 삭제됩니다.`)) return;
  btn.textContent = "…"; btn.disabled = true;
  const { error } = await sb.from("inventory_hangers").delete().eq("id", id);
  if (error) { appAlert("삭제 실패: " + error.message); btn.textContent = "삭제"; btn.disabled = false; return; }
  load();
}

// 차시 이름: 에코옥션·야후옥션은 연도+순번(SB2604 → 2026년 4차), 나머지는 번호(CR9 → 9차). 접두어는 화면에 쓰지 않는다.
function roundLabel(round) {
  if (!round) return "차시";
  const m = round.match(/^(?:SB|YH)(\d{2})(\d{2})$/);
  if (m) return `20${m[1]}년 ${+m[2]}차`;
  const n = round.match(/(\d+)$/);
  return n ? `${+n[1]}차` : round;
}

// 차시 라벨. 행거의 출처와 차시의 출처가 다르면(여러 출처를 한 차시로 합친 경우) 차시 출처 이름을 앞에 붙인다.
function batchTag(h) {
  const b = BATCHES.find(x => x.id === h.purchase_batch_id);
  if (!b) return "차시";
  const owner = [...PURCHASE_SRC].find(([, id]) => id === b.source_id)?.[0];
  return (owner && owner !== h.source ? owner + " · " : "") + roundLabel(b.round_code);
}

// 사입 출처를 고르면 진행 중인 차시(번호)를 고르게 한다. 의류/잡화는 고르지 않는다: 입고 승인 때 물건 카테고리로 같은 회차의 의류·잡화 차시에 자동으로 들어간다.
// 에코옥션·야후옥션처럼 여러 출처가 한 차시로 합쳐 들어오는 경우가 있어, 고른 출처의 차시 아래에 다른 출처의 진행 중 차시도 보여준다.
// 진행 중인 차시가 하나도 없으면 선택란을 숨기고(차시 없이 입고) 나중에 사입 통계 > 점검에서 배정한다.
function updateBatchSelect() {
  const group = document.getElementById("batch-group"), sel = document.getElementById("batch-select");
  if (!group || !sel) return;
  const name = document.getElementById("source-select").value;
  const srcId = PURCHASE_SRC.get(name);
  const mine = new Map(), others = new Map();   // 출처id|round_code → 대표 차시 id(의류 우선). 어느 쪽 id를 붙여도 같은 회차로 처리된다.
  if (srcId) {
    for (const b of BATCHES) {
      if (b.status !== "open") continue;
      const dst = b.source_id === srcId ? mine : others, key = b.source_id + "|" + b.round_code;
      if (!dst.has(key) || b.kind === "의류") dst.set(key, { id: b.id, round: b.round_code, srcId: b.source_id });
    }
  }
  const nameOf = id => [...PURCHASE_SRC].find(([, v]) => v === id)?.[0] || "";
  const opt = (r, withSrc) => `<option value="${escapeHtml(r.id)}">${escapeHtml((withSrc ? nameOf(r.srcId) + " · " : "") + roundLabel(r.round))}</option>`;
  group.style.display = mine.size + others.size ? "" : "none";
  sel.innerHTML = '<option value="">차시를 선택하세요</option>'
    + (mine.size ? `<optgroup label="${escapeHtml(name)} 차시">${[...mine.values()].map(r => opt(r, false)).join("")}</optgroup>` : "")
    + (others.size ? `<optgroup label="다른 출처 차시 (한 차시로 합쳐 들어온 경우)">${[...others.values()].map(r => opt(r, true)).join("")}</optgroup>` : "");
}

async function addHanger() {
  const hanger_number = document.getElementById("hanger-number").value.trim();
  const submitted_by  = MY_NAME;
  const source        = document.getElementById("source-select").value;
  if (!hanger_number) { showError("행거 번호를 입력하세요"); return; }
  if (!submitted_by) { showError("계정에 이름이 설정돼 있지 않아 행거를 추가할 수 없어요. 관리자에게 요청해 주세요."); return; }
  if (!source)       { showError("출처(거래처)를 선택하세요"); return; }
  const batchShown = document.getElementById("batch-group")?.style.display !== "none";
  const purchase_batch_id = batchShown ? document.getElementById("batch-select").value : "";
  if (batchShown && !purchase_batch_id) { showError("차시를 선택하세요"); return; }
  try {
    const { data: dup, error: dupErr } = await sb
      .from("inventory_hangers")
      .select("id")
      .eq("session_id", SESSION_ID)
      .eq("hanger_number", hanger_number)
      .maybeSingle();
    if (dupErr) throw dupErr;
    if (dup) { showError(`행거 ${hanger_number}은(는) 이미 이 세션에 있습니다.`); return; }

    const { data, error } = await sb
      .from("inventory_hangers")
      // category는 DB상 NOT NULL이라 빈 문자열로 채움 — 실제 카테고리는 item 단위로만 관리됨
      .insert({ session_id: SESSION_ID, hanger_number, category: "", submitted_by, source, ...(purchase_batch_id ? { purchase_batch_id } : {}) })
      .select()
      .single();
    if (error) throw error;
    setMyName(submitted_by);
    location.href = "hanger.html?id=" + encodeURIComponent(data.id);
  } catch (e) {
    showError("행거 추가 실패: " + e.message);
  }
}

load();
