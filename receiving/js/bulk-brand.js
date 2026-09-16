const HANGER_ID = getParam("id");
let queue = [];
let cursor = 0;
let results = [];
let isBusy = false;
let brandDropdownTimer = null;

async function init() {
  if (!HANGER_ID) { showError("행거 ID 없음"); return; }
  try {
    const { data: items, error } = await sb
      .from("inventory_items")
      .select("id, brand, price, photo_url, order_index")
      .eq("hanger_id", HANGER_ID)
      .order("order_index", { ascending: true });
    if (error) throw error;

    queue = (items || []).sort((a, b) => (a.order_index ?? 0) - (b.order_index ?? 0));
    document.getElementById("back-btn").href =
      `hanger.html?id=${encodeURIComponent(HANGER_ID)}`;
    if (queue.length === 0) { renderDone(true); return; }

    results = [];
    cursor = 0;
    advanceCursor();
    cursor >= queue.length ? renderDone(false) : render();
  } catch (e) {
    showError("로드 실패: " + e.message);
  }
}

function advanceCursor() {
  while (cursor < queue.length && queue[cursor].brand) {
    results.push({ item_id: queue[cursor].id, brand: queue[cursor].brand });
    cursor++;
  }
}

function render() {
  const item = queue[cursor];
  document.getElementById("brand-area").innerHTML = `
    <div class="bp-counter">${cursor + 1} / ${queue.length}</div>
    <div class="bp-hud">
      ${item.photo_url ? `<img src="${escapeHtml(item.photo_url)}" style="width:72px;height:72px;border-radius:8px;object-fit:cover;margin-bottom:10px">` : ""}
      <div class="bp-price">₩${(item.price || 0).toLocaleString()}</div>
    </div>
    <div style="position:relative;margin:12px 0 8px">
      <input type="text" id="brand-input" placeholder="브랜드명 입력" autocomplete="off" autocorrect="off" spellcheck="false"
        style="width:100%;padding:14px;border:1px solid #334155;border-radius:8px;background:#1e293b;color:#f1f5f9;font-size:16px;font-weight:600;box-sizing:border-box">
      <div id="brand-dropdown" style="display:none;position:absolute;top:100%;left:0;right:0;background:#1e293b;border:1px solid #334155;border-radius:8px;margin-top:4px;z-index:100;overflow:hidden;box-shadow:0 4px 16px rgba(0,0,0,.4)"></div>
    </div>
    <div style="display:flex;gap:8px;margin-bottom:16px">
      <button type="button" class="btn btn-outline btn-sm preset-btn" data-brand="Vintage" style="flex:1">Vintage</button>
      <button type="button" class="btn btn-outline btn-sm preset-btn" data-brand="SPA" style="flex:1">SPA</button>
      <button type="button" class="btn btn-outline btn-sm preset-btn" data-brand="보세" style="flex:1">보세</button>
    </div>
    <button id="save-btn" class="bp-capture-btn" disabled>저장하고 다음 →</button>
    <button class="bp-skip-btn" id="skip-btn">건너뜀 →</button>
  `;

  const brandInput = document.getElementById("brand-input");
  brandInput.addEventListener("input", onBrandInput);
  brandInput.addEventListener("blur", () => setTimeout(hideBrandDropdown, 150));
  brandInput.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); saveBrand(); } });
  document.getElementById("save-btn").addEventListener("click", saveBrand);
  document.getElementById("skip-btn").addEventListener("click", skip);
  document.querySelectorAll(".preset-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      brandInput.value = btn.dataset.brand;
      hideBrandDropdown();
      updateSaveBtn();
    });
  });

  setTimeout(() => brandInput.focus(), 80);
  renderTray();
}

function onBrandInput() {
  updateSaveBtn();
  const q = (document.getElementById("brand-input")?.value || "").trim();
  clearTimeout(brandDropdownTimer);
  if (q.length < 2) { hideBrandDropdown(); return; }
  brandDropdownTimer = setTimeout(() => showBrandDropdown(q), 300);
}

async function showBrandDropdown(q) {
  const [{ data: prefixData }, { data: containsData }] = await Promise.all([
    sb.from("brand_master").select("name").ilike("name", `${q}%`).order("name").limit(8),
    sb.from("brand_master").select("name").ilike("name", `%${q}%`).order("name").limit(8),
  ]);
  const seen = new Set();
  const brands = [];
  for (const b of [...(prefixData || []), ...(containsData || [])].map(it => it.name).filter(Boolean)) {
    const key = b.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    brands.push(b);
    if (brands.length >= 8) break;
  }
  const dd = document.getElementById("brand-dropdown");
  if (!dd) return;
  if (brands.length === 0) { hideBrandDropdown(); return; }
  dd.innerHTML = brands.map(b =>
    `<div data-brand="${escapeHtml(b)}" style="padding:10px 14px;font-size:14px;color:#e2e8f0;cursor:pointer;border-bottom:1px solid #0f172a">${escapeHtml(b)}</div>`
  ).join("");
  dd.style.display = "block";
  dd.querySelectorAll("div").forEach(item => {
    item.addEventListener("mousedown", () => {
      document.getElementById("brand-input").value = item.dataset.brand;
      hideBrandDropdown();
      updateSaveBtn();
    });
  });
}

function hideBrandDropdown() {
  const dd = document.getElementById("brand-dropdown");
  if (dd) dd.style.display = "none";
}

function updateSaveBtn() {
  const btn   = document.getElementById("save-btn");
  const input = document.getElementById("brand-input");
  if (btn && input) btn.disabled = isBusy || input.value.trim().length === 0;
}

function setBusy(busy) {
  isBusy = busy;
  const skipBtn = document.getElementById("skip-btn");
  if (skipBtn) skipBtn.disabled = busy;
  const tray = document.getElementById("tray");
  if (tray) tray.style.pointerEvents = busy ? "none" : "";
}

async function saveBrand() {
  const brandInput = document.getElementById("brand-input");
  const brand = brandInput?.value.trim();
  if (!brand || isBusy) return;

  const saveBtn = document.getElementById("save-btn");
  if (saveBtn) saveBtn.textContent = "저장 중…";
  setBusy(true);

  const item = queue[cursor];
  try {
    const { error } = await sb
      .from("inventory_items")
      .update({ brand })
      .eq("id", item.id);
    if (error) throw new Error(error.message);

    item.brand = brand;
    results[cursor] = { item_id: item.id, brand };
    cursor++;
    advanceCursor();
    setBusy(false);
    cursor >= queue.length ? renderDone(false) : render();
  } catch (err) {
    setBusy(false);
    showError("저장 실패: " + err.message);
    if (saveBtn) saveBtn.textContent = "저장하고 다음 →";
  }
}

function skip() {
  if (isBusy) return;
  results.push({ item_id: queue[cursor].id, brand: null });
  cursor++;
  advanceCursor();
  cursor >= queue.length ? renderDone(false) : render();
}

function renderTray() {
  const tray = document.getElementById("tray");
  if (!results.length) { tray.innerHTML = ""; return; }
  tray.innerHTML = results.map((r, i) =>
    r.brand
      ? `<div class="bp-list-row">
           <span class="bp-list-num">${i + 1}</span>
           <span class="bp-list-brand">${escapeHtml(r.brand)}</span>
           <i class="ph-bold ph-check" style="color:#22c55e;font-size:14px;flex-shrink:0"></i>
         </div>`
      : `<div class="bp-list-row skipped">
           <span class="bp-list-num">${i + 1}</span>
           <span class="bp-list-brand" style="color:var(--fg-tertiary)">건너뜀</span>
         </div>`
  ).reverse().join("");
}

function renderDone(allDone) {
  const saved   = results.filter(r => r.brand).length;
  const skipped = results.filter(r => !r.brand).length;
  document.getElementById("brand-area").innerHTML = `
    <div class="bp-done">
      <div class="bp-done-icon">${allDone ? "✓" : "🏷️"}</div>
      <div class="bp-done-title">${allDone ? "모든 브랜드가 이미 입력되어 있습니다" : "브랜드 입력 완료"}</div>
      ${!allDone ? `<div class="bp-done-sub">${saved}개 저장 · ${skipped}개 건너뜀</div>` : ""}
      <a href="hanger.html?id=${encodeURIComponent(HANGER_ID)}" class="btn btn-success mt16">행거로 돌아가기</a>
    </div>
  `;
  renderTray();
}

init();
