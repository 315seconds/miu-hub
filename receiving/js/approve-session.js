const SESSION_ID = getParam("id");
const STATUS_LABEL = { pending: "대기중", approved: "승인됨", processed: "처리완료", expired: "만료됨" };
let SESS = null;
let HANGERS = [];
let TOTAL = 0;
let HANDLERS = [];

async function load() {
  if (!SESSION_ID) { showError("세션 ID 없음"); return; }
  try {
    const [{ data: sess, error: se }, { data: hangers, error: he }, { data: handlers }] = await Promise.all([
      sb.from("inventory_sessions").select("*").eq("id", SESSION_ID).single(),
      sb.from("inventory_hangers").select("*, inventory_items(*)").eq("session_id", SESSION_ID).order("created_at", { ascending: true }),
      sb.from("handlers").select("name").eq("is_active", true).order("name"),
    ]);
    if (se) throw se;
    if (he) throw he;

    SESS     = sess;
    HANGERS  = hangers || [];
    TOTAL    = HANGERS.reduce((s, h) => s + (h.inventory_items || []).length, 0);
    HANDLERS = handlers || [];

    const suggested = await getSuggestedFromDb(sess.barcode_prefix);
    render(suggested);
  } catch (e) {
    showError("로드 실패: " + e.message);
  }
}

async function getSuggestedFromDb(prefix) {
  const { data: maxNum, error } = await sb.rpc("max_barcode_num", { p_prefix: prefix });
  if (error) { console.warn("바코드 최댓값 조회 실패:", error.message); return null; }
  return maxNum != null ? maxNum + 1 : null;
}

function render(suggested) {
  const titleEl = document.getElementById("page-title");
  const badgeEl = document.getElementById("page-badge");
  if (titleEl) titleEl.textContent = SESS.session_date;
  if (badgeEl) badgeEl.innerHTML = `<span class="badge badge-${escapeHtml(SESS.status)}">${STATUS_LABEL[SESS.status] || SESS.status}</span>`;

  let html = `
    <div class="card text-sm" style="margin-bottom:16px">
      <div class="flex" style="gap:16px; flex-wrap:wrap">
        <span class="muted">접두사: <strong style="color:var(--fg-primary)">${escapeHtml(SESS.barcode_prefix)}</strong></span>
        <span class="muted">위치: <strong style="color:var(--fg-primary)">${escapeHtml(SESS.location || "")}</strong></span>
        ${SESS.created_by ? `<span class="muted">개설: ${escapeHtml(SESS.created_by)}</span>` : ""}
      </div>
      <div class="mt8">
        <strong style="color:var(--brand-primary); font-size:18px">총 ${TOTAL}벌</strong>
        <span class="muted text-sm">&nbsp;·&nbsp;행거 ${HANGERS.length}개</span>
      </div>
    </div>
  `;

  if (SESS.status === "pending") {
    html += `
      <div class="card card-pending" style="margin-bottom:16px">
        <h2 style="color:var(--brand-primary); margin-bottom:12px">바코드 부여 &amp; 승인</h2>
        <div class="card" style="background:var(--bg-secondary); padding:10px 14px; margin-bottom:14px">
          ${suggested ? `
            <div class="text-xs muted">DB 기준 추천 시작 번호</div>
            <div class="mono" style="font-size:20px; font-weight:700; color:var(--brand-primary)">
              ${escapeHtml(SESS.barcode_prefix)}${suggested}
            </div>
            <div class="text-xs muted mt8">
              끝 바코드: ${escapeHtml(SESS.barcode_prefix)}${suggested + TOTAL - 1} (${TOTAL}벌)
            </div>` : `
            <div class="text-xs warn">⚠ DB에 기존 바코드 없음 — 시작 번호를 직접 입력하세요</div>`}
          <button type="button" class="btn btn-outline btn-sm mt8" id="excel-btn">📊 DB에서 재확인</button>
          <div id="excel-result" class="text-xs muted mt8" style="display:none"></div>
          <div style="margin-top:12px; background:var(--w-orange-95); border:1px solid var(--w-orange-90); border-radius:8px; padding:10px 12px; font-size:12px; color:var(--w-orange-60); line-height:1.6">
            ⚠️ 추천값은 자동 계산이라 실제와 다를 수 있어요. 반드시 확인 후 입력하세요.
          </div>
        </div>
        <div class="form-group">
          <label>시작 바코드 번호</label>
          <input type="number" id="start-barcode" value="${suggested || ""}" placeholder="예: 24578" inputmode="numeric">
        </div>
        <div class="form-group">
          <label>승인자 이름</label>
          <select id="approved-by">
            <option value="">승인자를 선택하세요</option>
            ${HANDLERS.map(h => `<option value="${escapeHtml(h.name)}">${escapeHtml(h.name)}</option>`).join("")}
          </select>
        </div>
        <button id="confirm-btn" class="btn btn-success btn-block">✓ 승인하기</button>
      </div>
    `;
  } else if (SESS.status === "approved" && !SESS.excel_updated) {
    html += `
      <div class="card card-success" style="margin-bottom:16px">
        <div class="success" style="font-weight:700">✓ 승인됨 — 엑셀 기록 대기 중</div>
        <div class="text-sm muted mt8">서버 크론이 2분 내 입고 시트에 자동 기록합니다.</div>
        <div class="mt8 text-sm muted">
          시작 바코드: <strong class="success mono">
            ${escapeHtml(SESS.barcode_prefix)}${SESS.start_barcode_num}
          </strong>
          ~ ${escapeHtml(SESS.barcode_prefix)}${SESS.start_barcode_num + TOTAL - 1}
        </div>
        <button id="reopen-btn" class="btn btn-outline btn-sm mt8">승인 취소 (수정)</button>
      </div>
    `;
  } else if (SESS.status === "expired") {
    html += `
      <div class="card" style="border-color:#334155; background:#0f172a; margin-bottom:16px">
        <div style="color:#64748b; font-weight:700">❌ 만료됨</div>
        <div class="text-sm muted mt8">미제출 행거가 있어 만료 처리되었습니다.</div>
      </div>
    `;
  } else {
    html += `
      <div class="card" style="border-color:var(--w-violet-80); background:var(--w-violet-99); margin-bottom:16px">
        <div style="color:var(--w-violet-50); font-weight:700">✓ 처리 완료</div>
        <div class="text-sm muted mt8">
          바코드: <span class="mono">${escapeHtml(SESS.barcode_prefix)}${SESS.start_barcode_num}
          ~ ${escapeHtml(SESS.barcode_prefix)}${SESS.start_barcode_num + TOTAL - 1}</span>
        </div>
      </div>
    `;
  }

  if ((SESS.status === "approved" || SESS.status === "processed") && SESS.start_barcode_num) {
    html += `
      <div class="flex mb8" style="gap:8px">
        <a href="labels.html?session_id=${encodeURIComponent(SESS.id)}" target="_blank"
           class="btn btn-warn flex-1" style="text-align:center; text-decoration:none">🖨 라벨 출력</a>
      </div>
    `;
  }

  html += `<hr class="divider"><h2>행거별 아이템 목록</h2>`;
  if (HANGERS.length === 0) {
    html += '<div class="empty">행거가 없습니다</div>';
  } else {
    html += HANGERS.map(h => {
      const items = h.inventory_items || [];
      return `
        <div class="card">
          <div class="flex" style="align-items:center; margin-bottom:10px">
            <strong style="font-size:16px">행거 ${escapeHtml(h.hanger_number)}</strong>
            <span class="muted" style="margin-left:8px">${escapeHtml(h.category)}</span>
            <span class="muted text-sm" style="margin-left:auto">${items.length}벌</span>
            ${h.submitted_at
              ? `<span style="margin-left:8px; font-size:11px; color:var(--status-success)">✓ 제출</span>`
              : `<span style="margin-left:8px; font-size:11px; color:#ef4444; font-weight:600">미제출</span>`}
          </div>
          ${items.length === 0 ? '<div class="text-sm muted">아이템 없음</div>' :
            items.map((item, i) => `
              <div class="item-row">
                <span class="item-num">${i + 1}</span>
                <div class="item-info">
                  <div class="item-price">₩${(item.price || 0).toLocaleString()}</div>
                  ${item.brand ? `<div class="item-brand">${escapeHtml(item.brand)}</div>` : ""}
                  ${item.barcode ? `<div class="text-xs muted">${escapeHtml(item.barcode)}</div>` : ""}
                </div>
              </div>`).join("")}
        </div>`;
    }).join("");
  }

  document.getElementById("content").innerHTML = html;
  document.getElementById("confirm-btn")?.addEventListener("click", confirmApprove);
  document.getElementById("excel-btn")?.addEventListener("click", loadExcelSuggest);
  document.getElementById("reopen-btn")?.addEventListener("click", reopen);
}

async function confirmApprove() {
  const start_barcode_num = parseInt(document.getElementById("start-barcode").value.trim(), 10);
  const approved_by = document.getElementById("approved-by").value;
  if (!start_barcode_num) { showError("시작 바코드 번호 입력"); return; }
  if (!approved_by) { showError("승인자 이름을 선택하세요"); return; }
  const unsubmitted = HANGERS.filter(h => !h.submitted_at);
  if (unsubmitted.length > 0) {
    showError(`미제출 행거가 있습니다: 행거 ${unsubmitted.map(h => escapeHtml(h.hanger_number)).join(", ")}`);
    return;
  }
  if (!await appConfirm(`총 ${TOTAL}벌을 승인하시겠습니까?`)) return;
  try {
    const { error } = await sb
      .from("inventory_sessions")
      .update({ status: "approved", start_barcode_num, approved_by, approved_at: new Date().toISOString() })
      .eq("id", SESSION_ID);
    if (error) throw error;
    load();
  } catch (e) {
    showError("승인 실패: " + e.message);
  }
}

async function reopen() {
  if (!await appConfirm("승인을 취소하고 수정 모드로 돌아가시겠습니까?")) return;
  try {
    const { error } = await sb
      .from("inventory_sessions")
      .update({ status: "pending", start_barcode_num: null, approved_by: null, approved_at: null })
      .eq("id", SESSION_ID);
    if (error) throw error;
    load();
  } catch (e) {
    showError("취소 실패: " + e.message);
  }
}

async function loadExcelSuggest() {
  const btn = document.getElementById("excel-btn");
  const res = document.getElementById("excel-result");
  btn.textContent = "⏳ 로딩…"; btn.disabled = true;
  res.style.display = "none";
  try {
    const prefix = SESS.barcode_prefix;
    const { data: maxNum, error } = await sb.rpc("max_barcode_num", { p_prefix: prefix });
    if (error) throw error;

    if (maxNum == null) {
      res.textContent = "DB에 기존 바코드 없음 — 직접 입력하세요";
    } else {
      const suggested = maxNum + 1;
      document.getElementById("start-barcode").value = suggested;
      res.textContent = `✓ DB 기준: ${prefix}${maxNum} 다음 → ${prefix}${suggested}`;
      res.style.color = "var(--status-success)";
    }
    res.style.display = "block";
  } catch (e) {
    res.textContent = "오류: " + e.message;
    res.style.display = "block";
  } finally {
    btn.textContent = "📊 DB에서 재확인"; btn.disabled = false;
  }
}

load();
