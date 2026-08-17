const SESSION_ID = getParam("id");
const STATUS_LABEL = { pending: "대기중", approved: "승인됨", processed: "처리완료" };
let HANDLERS = [];

async function load() {
  if (!SESSION_ID) { showError("세션 ID 없음"); return; }
  try {
    const [{ data: sess, error: se }, { data: hangers, error: he }, { data: handlers }] = await Promise.all([
      sb.from("inventory_sessions").select("*").eq("id", SESSION_ID).single(),
      sb.from("inventory_hangers").select("*, inventory_items(*)").eq("session_id", SESSION_ID).order("created_at", { ascending: false }),
      sb.from("handlers").select("name").eq("is_active", true).order("name"),
    ]);
    if (se) throw se;
    if (he) throw he;
    HANDLERS = handlers || [];

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
          ~ ${escapeHtml(sess.barcode_prefix)}${sess.start_barcode_num + total - 1}
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
        <div class="flex mb8">
          <div class="form-group flex-1" style="margin-bottom:0">
            <label>행거 번호</label>
            <input type="text" id="hanger-number" placeholder="1, 2, A1 ..." autofocus>
          </div>
          <div class="form-group flex-1" style="margin-bottom:0">
            <label>카테고리</label>
            <input type="text" id="hanger-category" placeholder="자켓, 스웨터, 청바지 ...">
          </div>
        </div>
        <div class="form-group mt8">
          <label>담당자 (선택)</label>
          <select id="submitted-by">
            <option value="">담당자를 선택하세요</option>
            ${HANDLERS.map(h => `<option value="${escapeHtml(h.name)}"${h.name === getMyName() ? " selected" : ""}>${escapeHtml(h.name)}</option>`).join("")}
          </select>
        </div>
        <button id="add-hanger-btn" class="btn btn-success btn-block">행거 추가 →</button>
      </div>`;
  }

  if (hangers.length > 0) {
    const myName = getMyName();
    html += hangers.map(h => {
      const items = h.inventory_items || [];
      const isMine = !h.submitted_by || h.submitted_by === myName;
      return `
        <div class="card">
          <div class="flex" style="align-items:center; margin-bottom:8px">
            <span style="font-size:17px; font-weight:700; margin-right:8px">행거 ${escapeHtml(h.hanger_number)}</span>
            <span style="font-weight:600; color:var(--fg-secondary)">${escapeHtml(h.category)}</span>
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

async function addHanger() {
  const hanger_number = document.getElementById("hanger-number").value.trim();
  const category      = document.getElementById("hanger-category").value.trim();
  const submitted_by  = document.getElementById("submitted-by").value.trim();
  if (!hanger_number || !category) { showError("행거 번호와 카테고리를 입력하세요"); return; }
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
      .insert({ session_id: SESSION_ID, hanger_number, category, submitted_by })
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
