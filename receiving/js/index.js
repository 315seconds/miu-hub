function todayKST() {
  const kst = new Date(Date.now() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10);
}

async function cleanupOldPendingSessions(today) {
  const { data: oldPending, error } = await sb
    .from("inventory_sessions")
    .select("id, inventory_hangers(inventory_items(id))")
    .eq("status", "pending")
    .lt("session_date", today);
  if (error) { console.warn("cleanup 조회 실패:", error.message); return; }
  if (!oldPending || oldPending.length === 0) return;
  for (const s of oldPending) {
    const itemCount = (s.inventory_hangers || [])
      .reduce((sum, h) => sum + (h.inventory_items || []).length, 0);
    if (itemCount === 0) {
      const { error: delErr } = await sb.from("inventory_sessions").delete().eq("id", s.id);
      if (delErr) console.warn("세션 삭제 실패:", s.id, delErr.message);
    } else {
      const { error: upErr } = await sb.from("inventory_sessions").update({ status: "expired" }).eq("id", s.id);
      if (upErr) console.warn("세션 expired 처리 실패:", s.id, upErr.message);
    }
  }
}

const DONE_LIMIT = 10;

async function load() {
  try {
    const today = todayKST();
    document.getElementById("session-date").value = today;

    await cleanupOldPendingSessions(today);

    const [pendingRes, doneRes] = await Promise.all([
      sb.from("inventory_sessions")
        .select("*, inventory_hangers(inventory_items(id))")
        .eq("status", "pending")
        .order("created_at", { ascending: false }),
      sb.from("inventory_sessions")
        .select("*, inventory_hangers(inventory_items(id))")
        .in("status", ["approved", "processed"])
        .order("created_at", { ascending: false })
        .limit(DONE_LIMIT),
    ]);
    if (pendingRes.error) throw pendingRes.error;
    if (doneRes.error) throw doneRes.error;

    const addTotal = s => {
      s.total_items = (s.inventory_hangers || [])
        .reduce((sum, h) => sum + (h.inventory_items || []).length, 0);
    };
    (pendingRes.data || []).forEach(addTotal);
    (doneRes.data || []).forEach(addTotal);

    render(pendingRes.data || [], doneRes.data || []);
  } catch (e) {
    showError("세션 목록 로드 실패: " + e.message);
  }
}

function render(pending, done) {
  const ps = document.getElementById("pending-section");
  if (pending.length === 0) {
    ps.innerHTML = `
      <div class="card" style="background:#0f172a; text-align:center; padding:32px 16px; margin-bottom:16px">
        <div style="font-size:32px; margin-bottom:8px">📭</div>
        <div style="color:#64748b">진행 중인 세션이 없습니다</div>
        <div class="text-xs muted mt8">아래에서 새 세션을 만들어 시작하세요</div>
      </div>`;
  } else {
    ps.innerHTML = `<h2>지금 진행 중인 세션</h2>` +
      pending.map(s => `
        <div class="join-card">
          <a href="session.html?id=${encodeURIComponent(s.id)}" style="text-decoration:none; display:block; color:inherit">
            <h3>${escapeHtml(s.session_date)}
              <span style="font-size:15px; color:#93c5fd; font-weight:600"> · ${escapeHtml(s.barcode_prefix)}*</span>
              ${s.location === "온라인" ? '<span class="tag-online" style="margin-left:6px">온라인</span>' : ""}
            </h3>
            <div class="meta">${escapeHtml(s.location || "")}${s.created_by ? " · " + escapeHtml(s.created_by) : ""}</div>
          </a>
          <div style="display:flex; gap:8px; margin-top:10px">
            <a href="session.html?id=${encodeURIComponent(s.id)}" style="flex:1; text-decoration:none">
              <div class="btn btn-primary btn-block">참여하기 →</div>
            </a>
            <button class="del-session-btn" data-id="${escapeHtml(s.id)}"
              style="background:none; border:1px solid #ef4444; border-radius:6px; color:#ef4444; font-size:12px; padding:6px 12px; cursor:pointer; white-space:nowrap">
              삭제
            </button>
          </div>
        </div>`).join("");
  }

  const ds = document.getElementById("done-section");
  if (done.length > 0) {
    const labels = { approved: "승인됨", processed: "처리완료", expired: "만료됨" };
    ds.innerHTML = `<hr class="divider">
      <div class="muted text-sm mb8">최근 완료된 세션 ${done.length}건</div>` +
      done.map(s => `
        <a href="session.html?id=${encodeURIComponent(s.id)}" style="text-decoration:none">
          <div class="card" style="cursor:pointer; padding:12px 14px">
            <div class="flex" style="align-items:center">
              <span class="badge badge-${escapeHtml(s.status)}" style="margin-right:8px">${labels[s.status] || s.status}</span>
              <span class="text-sm">${escapeHtml(s.session_date)} · ${escapeHtml(s.barcode_prefix)}*</span>
              ${s.total_items ? `<span class="muted text-sm" style="margin-left:auto">${s.total_items}벌</span>` : ""}
            </div>
          </div>
        </a>`).join("") +
      (done.length === DONE_LIMIT
        ? `<a href="logs.html" class="btn btn-outline btn-block mt8" style="text-decoration:none">전체 입고 로그 보기 →</a>`
        : "");
  } else {
    ds.innerHTML = "";
  }
}

document.getElementById("pending-section").addEventListener("click", async e => {
  const btn = e.target.closest(".del-session-btn");
  if (!btn) return;
  e.preventDefault();
  const id = btn.dataset.id;
  if (!await appConfirm("이 세션과 모든 행거·아이템을 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.")) return;
  btn.textContent = "…"; btn.disabled = true;
  const { error } = await sb.from("inventory_sessions").delete().eq("id", id);
  if (error) { appAlert("삭제 실패: " + error.message); btn.textContent = "삭제"; btn.disabled = false; return; }
  load();
});

async function loadHandlers() {
  const sel = document.getElementById("created-by");
  const { data, error } = await sb.from("handlers").select("name").eq("is_active", true).order("name");
  if (error || !data?.length) {
    sel.innerHTML = '<option value="">담당자 정보 로드 실패</option>';
    return;
  }
  sel.innerHTML = '<option value="">담당자를 선택하세요</option>' +
    data.map(h => `<option value="${escapeHtml(h.name)}">${escapeHtml(h.name)}</option>`).join("");
}
loadHandlers();

document.getElementById("toggle-create").addEventListener("click", () => {
  const f = document.getElementById("create-form");
  f.style.display = f.style.display === "none" ? "block" : "none";
});

document.getElementById("create-btn").addEventListener("click", async () => {
  clearError();
  const created_by = document.getElementById("created-by").value;
  if (!created_by) { showError("담당자 이름을 선택하세요"); return; }
  const body = {
    session_date:   document.getElementById("session-date").value,
    barcode_prefix: document.getElementById("barcode-prefix").value.trim().toUpperCase() || "C",
    location:       document.getElementById("location").value,
    created_by,
    status:         "pending",
  };
  try {
    const { data, error } = await sb.from("inventory_sessions").insert(body).select().single();
    if (error) throw error;
    location.href = "session.html?id=" + encodeURIComponent(data.id);
  } catch (e) {
    showError("세션 생성 실패: " + e.message);
  }
});

load();
