const HANGER_ID = getParam("id");
let queue = [];
let cursor = 0;
let results = [];
let isBusy = false;

// 업로드 전 리사이즈(긴 변 1600px) + JPEG 재압축(85%) — 공동물류처럼 느린 회선에서 업로드 시간 단축용
async function compressImage(file, maxDim = 1600, quality = 0.85) {
  try {
    const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
    const scale = Math.min(1, maxDim / Math.max(bitmap.width, bitmap.height));
    const w = Math.round(bitmap.width * scale);
    const h = Math.round(bitmap.height * scale);
    const canvas = document.createElement("canvas");
    canvas.width = w; canvas.height = h;
    canvas.getContext("2d").drawImage(bitmap, 0, 0, w, h);
    bitmap.close();
    const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", quality));
    if (!blob) return file;
    return new File([blob], "photo.jpg", { type: "image/jpeg" });
  } catch (e) {
    console.warn("사진 압축 실패, 원본 업로드:", e.message);
    return file;
  }
}

async function init() {
  if (!HANGER_ID) { showError("행거 ID 없음"); return; }
  try {
    const { data: items, error } = await sb
      .from("inventory_items")
      .select("id, brand, price, order_index, photo_url")
      .eq("hanger_id", HANGER_ID)
      .order("order_index", { ascending: true });
    if (error) throw error;

    const sorted = (items || []).sort((a, b) => (a.order_index ?? 0) - (b.order_index ?? 0));
    queue = sorted.filter(it => !it.photo_url);
    document.getElementById("back-btn").href =
      `hanger.html?id=${encodeURIComponent(HANGER_ID)}`;
    if (queue.length === 0) { renderDone(true); return; }
    render();
  } catch (e) {
    showError("로드 실패: " + e.message);
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
      return `<div class="bp-thumb bp-thumb-skip" onclick="restartFrom(${i})">
        <span class="bp-thumb-num">${i + 1}</span>
        <span style="font-size:9px;color:#64748b">건너뜀</span>
      </div>`;
    }
    return `<div class="bp-thumb" onclick="restartFrom(${i})">
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
  const capturedCursor = cursor;

  try {
    const compressed = await compressImage(file);
    const url = await sbUploadPhoto(HANGER_ID, compressed);

    const { error } = await sb
      .from("inventory_items")
      .update({ photo_url: url })
      .eq("id", item.id);
    if (error) throw new Error(error.message);

    results[capturedCursor] = { item_id: item.id, url };
    if (cursor === capturedCursor) {
      cursor++;
      setBusy(false);
      cursor >= queue.length ? renderDone(false) : render();
    } else {
      setBusy(false);
      render();
    }
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
  cursor >= queue.length ? renderDone(false) : render();
}

async function restartFrom(fromIndex) {
  if (isBusy) return;
  const suffix = results.length - fromIndex > 1
    ? `\n이후 ${results.length - fromIndex}장도 함께 초기화됩니다.`
    : "";
  if (!await appConfirm(`${fromIndex + 1}번부터 다시 찍겠습니까?${suffix}`)) return;

  setBusy(true);
  const label = document.getElementById("capture-label");
  if (label) { label.textContent = "⏳ 초기화 중…"; label.style.pointerEvents = "none"; }

  const toReset = results.slice(fromIndex).filter(r => r.url);
  try {
    await Promise.all(
      toReset.map(r =>
        sb.from("inventory_items").update({ photo_url: null }).eq("id", r.item_id)
          .then(({ error }) => { if (error) throw new Error(error.message); })
      )
    );
  } catch (err) {
    setBusy(false);
    showError("초기화 실패: " + err.message + " — 다시 시도해주세요.");
    if (label) { label.textContent = "📷 촬영"; label.style.pointerEvents = ""; }
    return;
  }

  results = results.slice(0, fromIndex);
  cursor = fromIndex;
  setBusy(false);
  render();
}

function renderDone(allDone) {
  const taken   = results.filter(r => r.url).length;
  const skipped = results.filter(r => !r.url).length;
  document.getElementById("shoot-area").innerHTML = `
    <div class="bp-done">
      <div class="bp-done-icon">${allDone ? "✓" : "📷"}</div>
      <div class="bp-done-title">${allDone ? "모든 사진이 이미 있습니다" : "촬영 완료"}</div>
      ${!allDone ? `<div class="bp-done-sub">${taken}장 촬영 · ${skipped}장 건너뜀</div>` : ""}
      <a href="hanger.html?id=${encodeURIComponent(HANGER_ID)}" class="btn btn-success mt16">행거로 돌아가기</a>
    </div>
  `;
  document.getElementById("tray").innerHTML = "";
}

init();
