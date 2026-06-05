let currentFilter = "today";
const itemCache = {};

function toDateStr(d) { return d.toISOString().slice(0, 10); }

function getRange() {
  const now = new Date(), today = toDateStr(now);
  if (currentFilter === "today") return { from: today, to: today };
  if (currentFilter === "week") {
    const d = new Date(now); d.setDate(d.getDate() - 6);
    return { from: toDateStr(d), to: today };
  }
  if (currentFilter === "month") {
    return { from: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-01`, to: today };
  }
  return { from: document.getElementById("date-from").value, to: document.getElementById("date-to").value };
}

function formatDate(str) {
  const [y, m, d] = str.split("-");
  const days = ["일","월","화","수","목","금","토"];
  const day  = days[new Date(str).getDay()];
  return `${m}월 ${parseInt(d)}일 (${day})`;
}

document.querySelectorAll(".log-filter-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    currentFilter = btn.dataset.filter;
    document.querySelectorAll(".log-filter-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    const customEl = document.getElementById("custom-range");
    if (currentFilter === "custom") {
      customEl.classList.add("open");
      const today = toDateStr(new Date());
      document.getElementById("date-from").value = today;
      document.getElementById("date-to").value   = today;
      document.getElementById("log-list").innerHTML =
        '<div class="log-empty"><div class="log-empty-icon">📅</div><div>날짜를 설정 후 조회하세요</div></div>';
    } else {
      customEl.classList.remove("open");
      loadLog();
    }
  });
});
document.getElementById("custom-load-btn").addEventListener("click", loadLog);

async function loadLog() {
  const listEl = document.getElementById("log-list");
  listEl.innerHTML = '<div class="log-loading">불러오는 중...</div>';
  Object.keys(itemCache).forEach(k => delete itemCache[k]);

  const { from, to } = getRange();
  if (!from || !to) return;
  try {
    const { data: sessions, error } = await sb
      .from("inventory_sessions")
      .select("*, inventory_hangers(category, inventory_items(id))")
      .gte("session_date", from)
      .lte("session_date", to)
      .order("session_date", { ascending: false });
    if (error) throw error;

    sessions.forEach(s => {
      s.total_items = (s.inventory_hangers || [])
        .reduce((sum, h) => sum + (h.inventory_items || []).length, 0);
    });
    renderLog(sessions);
  } catch (e) {
    listEl.innerHTML = `<div class="log-empty"><div class="log-empty-icon">⚠️</div><div>오류: ${escapeHtml(e.message)}</div></div>`;
  }
}

function renderLog(sessions) {
  const listEl = document.getElementById("log-list");
  if (!sessions.length) {
    listEl.innerHTML = '<div class="log-empty"><div class="log-empty-icon">📭</div><div>해당 기간에 입고 기록이 없어요</div></div>';
    return;
  }
  const grouped = {};
  sessions.forEach(s => { (grouped[s.session_date] ||= []).push(s); });

  const doneSessions = sessions.filter(s => s.status === "approved" || s.status === "processed");
  const periodTotal  = doneSessions.reduce((sum, s) => sum + (s.total_items || 0), 0);

  // 위치별 → 카테고리별 집계
  const locationMap = {};
  doneSessions.forEach(s => {
    const loc = s.location || "미지정";
    if (!locationMap[loc]) locationMap[loc] = { total: 0, cats: {} };
    (s.inventory_hangers || []).forEach(h => {
      const cnt = (h.inventory_items || []).length;
      const cat = h.category || "미분류";
      locationMap[loc].total += cnt;
      locationMap[loc].cats[cat] = (locationMap[loc].cats[cat] || 0) + cnt;
    });
  });

  const dateSummary = {};
  doneSessions.forEach(s => {
    (dateSummary[s.session_date] ||= { total: 0 }).total += s.total_items || 0;
  });

  const statusLabel = { pending: "대기중", approved: "승인됨", processed: "처리완료", expired: "만료됨" };
  const statusClass = { pending: "badge-pending", approved: "badge-approved", processed: "badge-processed", expired: "badge-expired" };

  let html = "";
  if (periodTotal > 0) {
    let locHtml = "";
    Object.entries(locationMap).forEach(([loc, data]) => {
      locHtml += `
        <div style="margin-bottom:10px">
          <div style="display:flex; justify-content:space-between; font-size:13px; font-weight:700; color:#e2e8f0; padding-bottom:4px; border-bottom:1px solid var(--border)">
            <span>${escapeHtml(loc)}</span>
            <span style="color:var(--brand-primary)">${data.total}벌</span>
          </div>`;
      Object.entries(data.cats)
        .sort((a, b) => b[1] - a[1])
        .forEach(([cat, cnt]) => {
          locHtml += `
          <div style="display:flex; justify-content:space-between; font-size:12px; color:#64748b; padding:3px 0 0 10px">
            <span>${escapeHtml(cat)}</span>
            <span>${cnt}벌</span>
          </div>`;
        });
      locHtml += `</div>`;
    });
    html += `
      <div class="card" style="background:var(--bg-secondary); margin-bottom:16px; padding:14px 16px">
        <div style="display:flex; justify-content:space-between; align-items:baseline; margin-bottom:12px">
          <span class="text-xs muted">기간 입고 요약</span>
          <span style="font-size:20px; font-weight:700; color:var(--brand-primary)">${periodTotal}벌 <span class="text-xs muted" style="font-weight:400">${doneSessions.length}건</span></span>
        </div>
        ${locHtml}
      </div>`;
  }
  Object.entries(grouped).forEach(([date, list]) => {
    html += `<div class="log-date-group">${formatDate(date)}</div>`;
    const ds = dateSummary[date];
    if (ds && ds.total > 0) {
      html += `<div class="log-day-summary">
        <div class="log-day-total">📦 승인 완료 총 ${ds.total}벌</div>
      </div>`;
    }
    list.forEach(s => {
      const cnt = s.total_items || 0;
      html += `
        <div class="log-session-card" id="lsc-${escapeHtml(s.id)}">
          <div class="log-session-header" data-id="${escapeHtml(s.id)}" data-date="${escapeHtml(s.session_date)}" data-prefix="${escapeHtml(s.barcode_prefix)}">
            <span class="log-session-chevron" id="chv-${escapeHtml(s.id)}">▶</span>
            <div style="flex:1; min-width:0">
              <div style="font-size:14px; font-weight:700; color:#e2e8f0">
                ${escapeHtml(s.barcode_prefix)}* · ${cnt}벌
              </div>
              <div style="font-size:12px; color:#475569; margin-top:2px">
                ${escapeHtml(s.location || "")}${s.created_by ? " · " + escapeHtml(s.created_by) : ""}
                ${s.start_barcode_num ? ' · <span style="font-family:monospace; color:#64748b">' + escapeHtml(s.barcode_prefix) + s.start_barcode_num + '~</span>' : ""}
              </div>
            </div>
            <span class="badge ${statusClass[s.status] || "badge-pending"}" style="flex-shrink:0; font-size:11px">
              ${statusLabel[s.status] || s.status}
            </span>
          </div>
          <div class="log-session-body" id="lbody-${escapeHtml(s.id)}">
            <div class="log-loading" style="padding:12px 0">불러오는 중...</div>
          </div>
        </div>`;
    });
  });

  listEl.innerHTML = html;
  document.querySelectorAll(".log-session-header").forEach(h => {
    h.addEventListener("click", () => toggleSession(h.dataset.id));
  });
}

async function toggleSession(sessionId) {
  const body    = document.getElementById(`lbody-${sessionId}`);
  const chevron = document.getElementById(`chv-${sessionId}`);
  const isOpen  = body.classList.contains("open");
  if (isOpen) { body.classList.remove("open"); chevron.classList.remove("open"); return; }
  body.classList.add("open"); chevron.classList.add("open");

  if (itemCache[sessionId]) { renderSessionItems(sessionId, itemCache[sessionId]); return; }
  try {
    const { data: hangers, error } = await sb
      .from("inventory_hangers")
      .select("hanger_number, category, inventory_items(barcode, price, brand)")
      .eq("session_id", sessionId)
      .order("created_at", { ascending: true });
    if (error) throw error;
    const mapped = (hangers || []).map(h => ({
      hanger_number: h.hanger_number,
      category:      h.category,
      items:         h.inventory_items || [],
    }));
    itemCache[sessionId] = mapped;
    renderSessionItems(sessionId, mapped);
  } catch (e) {
    body.innerHTML = `<div style="color:#f87171; font-size:13px">오류: ${escapeHtml(e.message)}</div>`;
  }
}

function renderSessionItems(sessionId, hangers) {
  const body = document.getElementById(`lbody-${sessionId}`);
  if (!hangers.length) { body.innerHTML = '<div style="color:#475569; font-size:13px; padding:8px 0">행거 없음</div>'; return; }
  let html = "";
  hangers.forEach(h => {
    html += `<div style="font-size:11px; font-weight:700; color:#64748b; margin:10px 0 6px; text-transform:uppercase">
      행거 ${escapeHtml(h.hanger_number)} · ${escapeHtml(h.category)} · ${h.items.length}벌
    </div>`;
    h.items.forEach((item, i) => {
      html += `<div class="log-item-row">
        <span class="log-item-num">${i + 1}</span>
        <span class="log-item-bc">${escapeHtml(item.barcode || "—")}</span>
        <span class="log-item-name">${item.brand ? escapeHtml(item.brand) + " " : ""}${escapeHtml(h.category)}</span>
        <span class="log-item-price">₩${(item.price || 0).toLocaleString()}</span>
      </div>`;
    });
  });
  const header = document.querySelector(`.log-session-header[data-id="${sessionId}"]`);
  const date   = header ? header.dataset.date : sessionId;
  const prefix = header ? header.dataset.prefix : "";
  html += `<div style="margin-top:12px; text-align:right">
    <button onclick="downloadCSV('${sessionId}')"
      style="font-size:12px; padding:5px 12px; border:1px solid #334155; border-radius:6px; background:none; color:#64748b; cursor:pointer">
      ⬇ CSV 다운로드
    </button>
  </div>`;
  body.innerHTML = html;
}

function downloadCSV(sessionId) {
  const hangers = itemCache[sessionId];
  if (!hangers) return;
  const header = document.querySelector(`.log-session-header[data-id="${sessionId}"]`);
  const date   = header ? header.dataset.date : sessionId;
  const prefix = header ? header.dataset.prefix : "";

  const rows = [["행거번호", "카테고리", "바코드", "브랜드", "가격"]];
  hangers.forEach(h => {
    h.items.forEach(item => {
      rows.push([h.hanger_number, h.category, item.barcode || "", item.brand || "", item.price || 0]);
    });
  });

  const csv = rows.map(r => r.map(v => `"${String(v).replace(/"/g, '""')}"`).join(",")).join("\n");
  const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8;" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `입고_${date}_${prefix}.csv`;
  a.click();
}

loadLog();
