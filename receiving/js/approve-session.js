const SESSION_ID = getParam("id");
const STATUS_LABEL = { pending: "대기중", approved: "승인됨", processed: "처리완료", expired: "만료됨" };
let SESS = null;
let HANGERS = [];
let TOTAL = 0;
let MY_NAME = "";          // 로그인한 계정의 이름 (승인자로 자동 기록)
let PREVIEW_START = null;  // pending 세션의 예상 시작 바코드 (peek_next_barcode)

async function load() {
  if (!SESSION_ID) { showError("세션 ID 없음"); return; }
  try {
    const [{ data: sess, error: se }, { data: hangers, error: he }] = await Promise.all([
      sb.from("inventory_sessions").select("*").eq("id", SESSION_ID).single(),
      sb.from("inventory_hangers").select("*, inventory_items(*)").eq("session_id", SESSION_ID).order("created_at", { ascending: true }),
    ]);
    if (se) throw se;
    if (he) throw he;

    SESS     = sess;
    HANGERS  = hangers || [];
    TOTAL    = HANGERS.reduce((s, h) => s + (h.inventory_items || []).length, 0);
    // 승인자는 선택하지 않고 로그인한 계정 이름이 서버에서 자동 기록된다 (프로필은 auth-guard가 비동기로 불러옴)
    for (let i = 0; i < 50 && window.MIU_PROFILE === undefined; i++) await new Promise((r) => setTimeout(r, 100));
    MY_NAME = window.MIU_PROFILE?.name || "";

    // pending이면 예상 시작 바코드 미리보기 (시퀀스 소진 안 함)
    if (sess.status === "pending" && TOTAL > 0) {
      try {
        const { data: nextBc } = await sb.rpc("peek_next_barcode", { p_location: sess.location });
        PREVIEW_START = nextBc || null;
      } catch(e) { PREVIEW_START = null; }
    }

    render();
  } catch (e) {
    showError("로드 실패: " + e.message);
  }
}

function getBarcodeRange() {
  // 세션 아이템 중 이미 부여된 바코드 최소/최대
  const bcs = HANGERS.flatMap(h => (h.inventory_items || []).map(i => i.barcode)).filter(Boolean).sort();
  return bcs.length ? { first: bcs[0], last: bcs[bcs.length - 1], count: bcs.length } : null;
}

// 시작 바코드에서 count벌 만큼 이어진 끝 바코드 계산 (예: A26000226, 3 → A26000228)
function previewEndBarcode(start, count) {
  if (!start || count < 1) return start;
  const m = start.match(/^([A-Z]+\d{2,4})(\d+)$/);
  if (!m) return start;
  const [, head, tail] = m;
  const next = String(parseInt(tail, 10) + count - 1).padStart(tail.length, "0");
  return head + next;
}

function render() {
  const titleEl = document.getElementById("page-title");
  const badgeEl = document.getElementById("page-badge");
  if (titleEl) titleEl.textContent = SESS.session_date;
  if (badgeEl) badgeEl.innerHTML = `<span class="badge badge-${escapeHtml(SESS.status)}">${STATUS_LABEL[SESS.status] || SESS.status}</span>`;

  const range = getBarcodeRange();

  let html = `
    <div class="card text-sm" style="margin-bottom:16px">
      <div class="flex" style="gap:16px; flex-wrap:wrap">
        <span class="muted">위치: <strong style="color:var(--fg-primary)">${escapeHtml(SESS.location || "")}</strong></span>
        ${SESS.location === "온라인" ? '<span class="tag-online">온라인</span>' : ""}
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
        <div class="card" style="background:var(--bg-secondary); padding:12px 14px; margin-bottom:14px">
          ${PREVIEW_START ? `
            <div class="text-xs muted" style="margin-bottom:4px">예상 시작 바코드</div>
            <div class="mono" style="font-size:20px; font-weight:700; color:var(--brand-primary); letter-spacing:-.5px">
              ${escapeHtml(PREVIEW_START)}
            </div>
            <div class="text-xs muted" style="margin-top:6px">
              끝: <span class="mono">${escapeHtml(previewEndBarcode(PREVIEW_START, TOTAL))}</span> · 총 ${TOTAL}벌
            </div>
            <div class="text-xs muted" style="margin-top:10px; padding-top:10px; border-top:1px solid var(--hairline)">
              동시 승인이 있으면 실제 번호는 약간 앞뒤로 밀릴 수 있어요.
            </div>` : `
            <div class="text-sm" style="line-height:1.6">
              승인 시 아이템별로 자동 바코드가 부여됩니다.<br>
              <strong>${SESS.location === "온라인" ? "U + 년월(YYMM) + 4자리" : "A + 년(YY) + 6자리"}</strong> 형식으로 다음 순번부터 이어집니다.
            </div>`}
        </div>
        <div class="form-group">
          <label>승인자</label>
          <div class="text-sm">${MY_NAME
            ? `<strong>${escapeHtml(MY_NAME)}</strong> <span class="muted">(로그인한 계정으로 자동 기록돼요)</span>`
            : `<span class="danger">계정에 이름이 설정돼 있지 않아요. 관리자에게 요청해 주세요.</span>`}</div>
        </div>
        <button id="confirm-btn" class="btn btn-success btn-block">✓ 승인하기 (${TOTAL}벌 바코드 발행)</button>
      </div>
    `;
  } else if (SESS.status === "approved" && !SESS.excel_updated) {
    html += `
      <div class="card card-success" style="margin-bottom:16px">
        <div class="success" style="font-weight:700">✓ 승인됨 — 엑셀 기록 대기 중</div>
        <div class="text-sm muted mt8">서버 크론이 2분 내 입고 시트에 자동 기록합니다.</div>
        ${range ? `
        <div class="mt8 text-sm muted">
          바코드: <strong class="success mono">${escapeHtml(range.first)}</strong> ~ <strong class="success mono">${escapeHtml(range.last)}</strong>
          <span class="text-xs">(총 ${range.count}벌)</span>
        </div>` : ""}
        ${HANGERS.some(h => h.printed_at || h.kiosk_exported_at)
          ? `<div class="text-sm mt8" style="color:var(--status-danger)">라벨을 이미 출력했거나 키오스크 파일을 내려받아서 승인을 취소할 수 없어요. 번호가 바뀌면 붙인 라벨과 어긋나요.</div>`
          : `<button id="reopen-btn" class="btn btn-outline btn-sm mt8">승인 취소 (수정)</button>`}
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
        ${range ? `
        <div class="text-sm muted mt8">
          바코드: <span class="mono">${escapeHtml(range.first)} ~ ${escapeHtml(range.last)}</span> (총 ${range.count}벌)
        </div>` : ""}
      </div>
    `;
  }

  if ((SESS.status === "approved" || SESS.status === "processed") && range) {
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
      const cats = [...new Set(items.map(it => it.category).filter(Boolean))];
      return `
        <div class="card">
          <div class="flex" style="align-items:center; margin-bottom:10px">
            <strong style="font-size:16px">행거 ${escapeHtml(h.hanger_number)}</strong>
            <span class="muted" style="margin-left:8px">${cats.length ? escapeHtml(cats.join(" · ")) : "카테고리 미정"}</span>
            ${h.source ? `<span style="margin-left:8px;padding:2px 8px;font-size:11px;border-radius:6px;background:var(--miu-surface-soft, #f5f0e8);color:var(--miu-body, #3d3d3a)">${escapeHtml(h.source)}</span>` : ""}
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
  document.getElementById("reopen-btn")?.addEventListener("click", reopen);
}

async function confirmApprove() {
  if (!MY_NAME) { showError("계정에 이름이 설정돼 있지 않아 승인할 수 없어요. 관리자에게 요청해 주세요."); return; }
  const unsubmitted = HANGERS.filter(h => !h.submitted_at);
  if (unsubmitted.length > 0) {
    showError(`미제출 행거가 있습니다: 행거 ${unsubmitted.map(h => escapeHtml(h.hanger_number)).join(", ")}`);
    return;
  }
  if (TOTAL === 0) { showError("아이템이 없습니다"); return; }
  if (!await appConfirm(`총 ${TOTAL}벌에 자동 바코드를 부여하고 승인합니다.\n계속하시겠습니까?`)) return;

  const btn = document.getElementById("confirm-btn");
  const originalLabel = btn.textContent;
  btn.disabled = true;
  btn.textContent = "⏳ 바코드 부여 중…";

  try {
    // 서버에서 한 번에 처리한다: 바코드 발급, 상품 갱신, 승인 기록이 모두 성공하거나 모두 취소된다.
    // 동시에 다른 사람이 승인해도 번호가 섞이지 않고, 이미 승인된 세션은 다시 승인되지 않는다.
    const { error } = await sb.rpc("approve_inventory_session", { p_session_id: SESSION_ID });
    if (error) throw new Error(error.message);
    load();
  } catch (e) {
    showError("승인 실패: " + e.message);
    btn.disabled = false;
    btn.textContent = originalLabel;
  }
}

async function reopen() {
  if (!await appConfirm("승인을 취소하고 수정 모드로 돌아가시겠습니까?\n(이미 부여된 바코드는 남아있지만, 재승인 시 새 번호로 덮어써집니다)")) return;
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

load();
