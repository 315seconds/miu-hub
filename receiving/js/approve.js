const STATUS_LABEL = { approved: "승인됨", processed: "처리완료", expired: "만료됨" };

function todayKST() {
  return new Date(Date.now() + 9 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

async function load() {
  try {
    const today = todayKST();
    const [pendingRes, doneRes] = await Promise.all([
      sb.from("inventory_sessions")
        .select("*, inventory_hangers(inventory_items(id))")
        .eq("status", "pending")
        .order("created_at", { ascending: false }),
      sb.from("inventory_sessions")
        .select("*, inventory_hangers(inventory_items(id))")
        .eq("session_date", today)
        .in("status", ["approved", "processed"])
        .order("created_at", { ascending: false }),
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
    showError("승인 목록 로드 실패: " + e.message);
  }
}

function render(pending, done) {
  let html = "";
  if (pending.length > 0) {
    html += `<div class="muted text-sm mb8">승인 대기 ${pending.length}건</div>`;
    html += pending.map(s => `
      <a href="approve-session.html?id=${encodeURIComponent(s.id)}" style="text-decoration:none">
        <div class="card card-pending" style="cursor:pointer">
          <div class="flex" style="align-items:center; margin-bottom:6px">
            <span class="badge badge-pending" style="margin-right:8px">대기중</span>
            <strong>${escapeHtml(s.session_date)}</strong>
            <span class="muted text-sm" style="margin-left:8px">${escapeHtml(s.barcode_prefix)}*</span>
            ${s.total_items ? `<span class="muted text-sm" style="margin-left:auto">${s.total_items}벌</span>` : ""}
          </div>
          <div class="text-sm muted">
            ${escapeHtml(s.location || "")}
            ${s.created_by ? "&nbsp;· " + escapeHtml(s.created_by) : ""}
          </div>
          <div class="btn btn-primary btn-block mt8">승인하기 →</div>
        </div>
      </a>`).join("");
  } else {
    html += `
      <div class="card" style="text-align:center; padding:32px 16px">
        <div style="font-size:32px; margin-bottom:8px">✅</div>
        <div class="muted">대기 중인 세션이 없습니다</div>
      </div>`;
  }

  if (done.length > 0) {
    html += `<hr class="divider">
      <div class="muted text-sm mb8">오늘 처리 완료 ${done.length}건</div>`;
    html += done.map(s => `
      <a href="approve-session.html?id=${encodeURIComponent(s.id)}" style="text-decoration:none">
        <div class="card" style="cursor:pointer; padding:12px 14px">
          <div class="flex" style="align-items:center">
            <span class="badge badge-${escapeHtml(s.status)}" style="margin-right:8px">${STATUS_LABEL[s.status] || s.status}</span>
            <span class="text-sm">${escapeHtml(s.barcode_prefix)}*</span>
            ${s.total_items ? `<span class="muted text-sm" style="margin-left:auto">${s.total_items}벌</span>` : ""}
            ${s.excel_updated ? '<span class="success text-sm" style="margin-left:8px">✓ 엑셀</span>' : ""}
          </div>
        </div>
      </a>`).join("");
  }

  document.getElementById("content").innerHTML = html;
}

load();
