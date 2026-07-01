let currentFilter = "today";

function toDateStr(d) { return d.toISOString().slice(0, 10); }
function getRange() {
  const now = new Date(), today = toDateStr(now);
  if (currentFilter === "today") return { from: today, to: today };
  if (currentFilter === "week") {
    const d = new Date(now); d.setDate(d.getDate() - 6);
    return { from: toDateStr(d), to: today };
  }
  if (currentFilter === "month") {
    return { from: `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,"0")}-01`, to: today };
  }
  return { from: document.getElementById("date-from").value, to: document.getElementById("date-to").value };
}

document.querySelectorAll(".log-filter-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    currentFilter = btn.dataset.filter;
    document.querySelectorAll(".log-filter-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    const el = document.getElementById("custom-range");
    if (currentFilter === "custom") {
      el.classList.add("open");
      const today = toDateStr(new Date());
      document.getElementById("date-from").value = today;
      document.getElementById("date-to").value = today;
      document.getElementById("log-list").innerHTML =
        '<div class="log-empty"><div class="log-empty-icon">📅</div><div>날짜를 설정 후 조회하세요</div></div>';
    } else {
      el.classList.remove("open");
      loadLog();
    }
  });
});
document.getElementById("custom-load-btn").addEventListener("click", loadLog);

async function loadLog() {
  const listEl = document.getElementById("log-list");
  listEl.innerHTML = '<div class="log-loading">불러오는 중...</div>';
  const { from, to } = getRange();
  if (!from || !to) return;
  try {
    const [{ data: rows, error }, { data: failedRows, error: failedError }] = await Promise.all([
      sb.from("price_changes")
        .select("barcode, old_price, new_price, changed_by, changed_at")
        .gte("changed_at", `${from}T00:00:00+09:00`)
        .lte("changed_at", `${to}T23:59:59+09:00`)
        .eq("excel_failed", false)
        .order("changed_at", { ascending: false })
        .limit(500),
      sb.from("price_changes")
        .select("barcode, old_price, new_price, changed_by, changed_at")
        .eq("excel_failed", true)
        .order("changed_at", { ascending: false }),
    ]);
    if (error) throw error;
    if (failedError) throw failedError;

    // 날짜 → (담당자, HH:MM) 으로 그룹핑 (KST 기준)
    const dayMap = {};
    for (const r of (rows || [])) {
      const kst     = new Date(new Date(r.changed_at).getTime() + 9 * 60 * 60 * 1000).toISOString();
      const day     = kst.slice(0, 10);
      const timeStr = kst.slice(11, 16);
      const key     = `${r.changed_by || "미기재"}__${timeStr}`;
      if (!dayMap[day]) dayMap[day] = {};
      if (!dayMap[day][key]) dayMap[day][key] = { changed_by: r.changed_by || "미기재", time: timeStr, items: [] };
      dayMap[day][key].items.push(r);
    }
    const groups = Object.keys(dayMap).sort().reverse().map(date => ({
      date,
      sessions: Object.values(dayMap[date]).sort((a, b) => b.time.localeCompare(a.time)),
    }));
    renderLog(groups, failedRows || []);
  } catch (e) {
    listEl.innerHTML = `<div class="log-empty"><div class="log-empty-icon">⚠️</div><div>오류: ${escapeHtml(e.message)}</div></div>`;
  }
}

function renderLog(groups, failedRows = []) {
  const listEl = document.getElementById("log-list");
  let html = "";

  if (failedRows.length > 0) {
    html += `
      <div style="background:#2d1515; border:1px solid #ef4444; border-radius:10px; padding:14px; margin-bottom:16px">
        <div style="color:#ef4444; font-weight:700; font-size:14px; margin-bottom:10px">
          ⚠️ Excel 처리 실패 ${failedRows.length}건 — 수동 확인 필요
        </div>
        ${failedRows.map(r => {
          const kst = new Date(new Date(r.changed_at).getTime() + 9 * 60 * 60 * 1000).toISOString();
          return `<div class="item-row" style="border-top:1px solid #3d1a1a; padding-top:6px; margin-top:6px">
            <span style="font-family:monospace; color:#f87171; font-weight:700; flex-shrink:0; width:72px">${escapeHtml(r.barcode)}</span>
            <span style="flex:1; color:#94a3b8; font-size:12px">${kst.slice(0,10)} ${kst.slice(11,16)} · ${escapeHtml(r.changed_by || "미기재")}</span>
            <span class="price-old">${r.old_price ? "₩" + r.old_price.toLocaleString() : "—"}</span>
            <span class="price-arrow">→</span>
            <span style="color:#fbbf24; font-weight:700">₩${r.new_price.toLocaleString()}</span>
          </div>`;
        }).join("")}
      </div>`;
  }

  if (!groups.length) {
    html += '<div class="log-empty"><div class="log-empty-icon">📭</div><div>해당 기간에 수정 이력이 없습니다</div></div>';
    listEl.innerHTML = html;
    return;
  }
  groups.forEach(g => {
    const [y, m, d] = g.date.split("-");
    const days = ["일","월","화","수","목","금","토"];
    const dayName = days[new Date(g.date).getDay()];
    html += `<div class="date-group">${m}월 ${parseInt(d)}일 (${dayName})</div>`;
    g.sessions.forEach((s, si) => {
      const id = `cs-${g.date}-${si}`;
      html += `
        <div class="change-card">
          <div class="change-header" data-id="${id}">
            <span class="change-chevron" id="chv-${id}">▶</span>
            <div style="flex:1; min-width:0">
              <div style="font-size:14px; font-weight:700; color:#e2e8f0">
                ${escapeHtml(s.changed_by || "담당자 미기재")}
                <span style="font-size:12px; color:#64748b; font-weight:400; margin-left:6px">${escapeHtml(s.time)}</span>
              </div>
            </div>
            <span class="summary-pill">${s.items.length}건</span>
          </div>
          <div class="change-body" id="body-${id}">
            ${s.items.map(item => `
              <div class="item-row">
                <span style="font-family:monospace; color:#60a5fa; font-weight:700; flex-shrink:0; width:72px">${escapeHtml(item.barcode)}</span>
                <span style="flex:1; color:#94a3b8; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font-size:12px">${escapeHtml(item.product_name || "")}</span>
                <span class="price-old">${item.old_price ? "₩" + item.old_price.toLocaleString() : "—"}</span>
                <span class="price-arrow">→</span>
                <span style="color:#fbbf24; font-weight:700">₩${item.new_price.toLocaleString()}</span>
              </div>`).join("")}
          </div>
        </div>`;
    });
  });
  listEl.innerHTML = html;
  document.querySelectorAll(".change-header").forEach(h =>
    h.addEventListener("click", () => {
      const id = h.dataset.id;
      document.getElementById(`body-${id}`).classList.toggle("open");
      document.getElementById(`chv-${id}`).classList.toggle("open");
    })
  );
}

loadLog();
