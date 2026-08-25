const HANGER_ID = getParam("id");
let queue = [];
let cursor = 0;
let results = [];
let isBusy = false;
let retakeIndex = null;

// compressImage()는 js/api.js로 이동 (hanger.js 아이템 수정 모달과 공유)

async function init() {
  if (!HANGER_ID) { showError("행거 ID 없음"); return; }
  try {
    const { data: items, error } = await sb
      .from("inventory_items")
      .select("id, brand, price, order_index, photo_url")
      .eq("hanger_id", HANGER_ID)
      .order("order_index", { ascending: true });
    if (error) throw error;

    queue = (items || []).sort((a, b) => (a.order_index ?? 0) - (b.order_index ?? 0));
    document.getElementById("back-btn").href =
      `hanger.html?id=${encodeURIComponent(HANGER_ID)}`;
    document.getElementById("retake-file-input").addEventListener("change", onRetakeCapture);
    if (queue.length === 0) { renderDone(true); return; }

    results = [];
    cursor = 0;
    advanceCursor();
    cursor >= queue.length ? renderDone(false) : render();
  } catch (e) {
    showError("로드 실패: " + e.message);
  }
}

// cursor가 이미 사진이 있는 아이템(이전 세션에서 촬영 완료)을 가리키면 자동으로 건너뛰어
// 다음 미촬영 아이템에서 멈춘다 — results 배열 길이는 항상 cursor와 일치해야 함.
function advanceCursor() {
  while (cursor < queue.length && queue[cursor].photo_url) {
    results.push({ item_id: queue[cursor].id, url: queue[cursor].photo_url });
    cursor++;
  }
}

function render() {
  const item = queue[cursor];
  document.getElementById("shoot-area").innerHTML = `
    <div class="bp-counter">${cursor + 1} / ${queue.length}</div>
    <div class="bp-hud">
      <div class="bp-brand">${escapeHtml(item.brand || "(브랜드 없음)")}</div>
      <div class="bp-price">₩${(item.price || 0).toLocaleString()}</div>
    </div>
    <label class="bp-capture-btn" id="capture-label">
      📷 촬영
      <input type="file" accept="image/*" capture="environment" id="photo-file" style="display:none">
    </label>
    <button class="bp-skip-btn" id="skip-btn" onclick="skip()">건너뜀 →</button>
  `;
  document.getElementById("photo-file").addEventListener("change", onCapture);
  renderTray();
}

function renderTray() {
  const tray = document.getElementById("tray");
  if (!results.length) { tray.innerHTML = ""; return; }
  tray.innerHTML = results.map((r, i) => {
    if (!r.url) {
      return `<div class="bp-thumb bp-thumb-skip" onclick="retakeItem(${i})">
        <span class="bp-thumb-num">${i + 1}</span>
        <span style="font-size:9px;color:#64748b">건너뜀</span>
      </div>`;
    }
    return `<div class="bp-thumb" onclick="retakeItem(${i})">
      <img src="${escapeHtml(r.url)}" alt="${i + 1}">
      <span class="bp-thumb-num">${i + 1}</span>
    </div>`;
  }).join("");
  tray.scrollLeft = tray.scrollWidth;
}

function setBusy(busy) {
  isBusy = busy;
  const skipBtn = document.getElementById("skip-btn");
  if (skipBtn) skipBtn.disabled = busy;
  const tray = document.getElementById("tray");
  if (tray) tray.style.pointerEvents = busy ? "none" : "";
}

async function onCapture(e) {
  const file = e.target.files[0];
  if (!file || isBusy) return;

  const label = document.getElementById("capture-label");
  label.textContent = "⏳ 업로드 중…";
  label.style.pointerEvents = "none";
  setBusy(true);

  const item = queue[cursor];

  try {
    const compressed = await compressImage(file);
    const url = await sbUploadPhoto(HANGER_ID, compressed);

    const { error } = await sb
      .from("inventory_items")
      .update({ photo_url: url })
      .eq("id", item.id);
    if (error) throw new Error(error.message);

    results[cursor] = { item_id: item.id, url };
    item.photo_url = url;
    cursor++;
    advanceCursor();
    setBusy(false);
    cursor >= queue.length ? renderDone(false) : render();
  } catch (err) {
    setBusy(false);
    showError("사진 업로드 실패: " + err.message);
    label.textContent = "📷 촬영";
    label.style.pointerEvents = "";
  }
}

function skip() {
  if (isBusy) return;
  results.push({ item_id: queue[cursor].id, url: null });
  cursor++;
  advanceCursor();
  cursor >= queue.length ? renderDone(false) : render();
}

// 트레이의 사진(이미 촬영됐거나 건너뛴 것 모두)을 탭하면 그 아이템 한 장만 재촬영한다.
// 이후 아이템들은 건드리지 않는다 — 이미 완료된 행거를 통째로 다시 찍게 만들지 않기 위함.
function retakeItem(index) {
  if (isBusy) return;
  retakeIndex = index;
  document.getElementById("retake-file-input").click();
}

async function onRetakeCapture(e) {
  const file = e.target.files[0];
  e.target.value = "";
  const index = retakeIndex;
  retakeIndex = null;
  if (!file || isBusy || index === null || !queue[index]) return;

  const item = queue[index];
  const label = document.getElementById("capture-label");
  if (label) label.style.pointerEvents = "none";
  setBusy(true);

  try {
    const compressed = await compressImage(file);
    const url = await sbUploadPhoto(HANGER_ID, compressed);

    const { error } = await sb
      .from("inventory_items")
      .update({ photo_url: url })
      .eq("id", item.id);
    if (error) throw new Error(error.message);

    results[index] = { item_id: item.id, url };
    item.photo_url = url;
    renderTray();
  } catch (err) {
    showError("재촬영 실패: " + err.message);
  } finally {
    setBusy(false);
    if (label) label.style.pointerEvents = "";
  }
}

function renderDone(allDone) {
  const taken   = results.filter(r => r.url).length;
  const skipped = results.filter(r => !r.url).length;
  document.getElementById("shoot-area").innerHTML = `
    <div class="bp-done">
      <div class="bp-done-icon">${allDone ? "✓" : "📷"}</div>
      <div class="bp-done-title">${allDone ? "모든 사진이 이미 있습니다" : "촬영 완료"}</div>
      ${!allDone ? `<div class="bp-done-sub">${taken}장 촬영 · ${skipped}장 건너뜀</div>` : ""}
      ${results.length ? `<div class="text-xs muted mt8" style="text-align:center">아래 사진을 탭하면 그 아이템만 다시 촬영할 수 있습니다</div>` : ""}
      <a href="hanger.html?id=${encodeURIComponent(HANGER_ID)}" class="btn btn-success mt16">행거로 돌아가기</a>
    </div>
  `;
  renderTray();
}

init();
