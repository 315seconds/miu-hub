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
      sb.from("profiles").select("name").eq("is_handler", true).not("name", "is", null).order("name"),
    ]);
    if (se) throw se;
    if (he) throw he;

    SESS     = sess;
    HANGERS  = hangers || [];
    TOTAL    = HANGERS.reduce((s, h) => s + (h.inventory_items || []).length, 0);
    HANDLERS = handlers || [];

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
        <div class="card" style="background:var(--bg-secondary); padding:10px 14px; margin-bottom:14px">
          <div class="text-sm" style="line-height:1.6">
            승인 시 아이템별로 자동 바코드가 부여됩니다.<br>
            <strong>${SESS.location === "온라인" ? "U + 년월(YYMM) + 4자리" : "A + 년(YY) + 6자리"}</strong> 형식으로 다음 순번부터 이어집니다.
          </div>
        </div>
        <div class="form-group">
          <label>승인자 이름</label>
          <select id="approved-by">
            <option value="">승인자를 선택하세요</option>
            ${HANDLERS.map(h => `<option value="${escapeHtml(h.name)}">${escapeHtml(h.name)}</option>`).join("")}
          </select>
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
  const approved_by = document.getElementById("approved-by").value;
  if (!approved_by) { showError("승인자 이름을 선택하세요"); return; }
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
    // 모든 아이템 순서대로 (행거 created_at ASC → item order_index/created_at ASC)
    const items = HANGERS.flatMap(h => (h.inventory_items || [])
      .slice()
      .sort((a, b) => (a.order_index ?? 0) - (b.order_index ?? 0) || (a.created_at || "").localeCompare(b.created_at || ""))
    );

    // 각 아이템별로 next_barcode() RPC 호출
    const updates = [];
    for (let i = 0; i < items.length; i++) {
      btn.textContent = `⏳ 바코드 부여 중… (${i + 1}/${items.length})`;
      const { data: bc, error } = await sb.rpc("next_barcode", { p_location: SESS.location });
      if (error) throw new Error("바코드 발행 실패: " + error.message);
      updates.push({ id: items[i].id, barcode: bc });
    }

    btn.textContent = "⏳ 저장 중…";

    // 각 아이템 UPDATE (Supabase는 배치 UPDATE with different values가 없어서 개별 호출)
    // 성능: TOTAL 100개까지는 실측 2~3초. 그 이상이면 upsert 병렬화 고려.
    for (const u of updates) {
      const { error } = await sb.from("inventory_items").update({ barcode: u.barcode }).eq("id", u.id);
      if (error) throw error;
    }

    // 세션 상태 업데이트
    const firstBarcode = updates[0]?.barcode;
    const numSuffix = firstBarcode ? firstBarcode.replace(/^[A-Z]+/, "") : null;  // "A26000226" → "26000226"
    const { error: sessErr } = await sb
      .from("inventory_sessions")
      .update({
        status: "approved",
        start_barcode_num: numSuffix,   // 레거시 표시용, 첫 아이템 뒷자리만
        approved_by,
        approved_at: new Date().toISOString(),
      })
      .eq("id", SESSION_ID);
    if (sessErr) throw sessErr;

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
