const HANGER_ID = getParam("id");
const CATEGORIES = [
  "자켓", "바람막이", "플리스", "PK셔츠", "셔츠", "스웻셔츠", "반팔티", "긴팔티", "나시티", "스웨터",
  "하와이안셔츠", "타이다이", "원피스", "스커트", "반바지", "긴바지", "트랙팬츠", "블라우스",
  "신발", "가방", "패션잡화", "넥타이", "벨트", "패브릭", "셋업", "모자", "C",
];
function categoryLabel(c) { return c === "C" ? "C(균일가)" : c; }

let SESSION = null;
let HANGER  = null;
let CURRENT_ITEMS = [];
let currentCategory = "";
let itemCount = 0;
let unphotographedCount = 0;
let refVisible = false;
let refDebounceTimer = null;
let sessionBrands = [];
let todayBrands = [];
let brandDropdownTimer = null;

function localDateStr(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

async function load() {
  if (!HANGER_ID) { showError("행거 ID 없음"); return; }
  try {
    const { data: hanger, error: he } = await sb
      .from("inventory_hangers")
      .select("*, inventory_sessions(*)")
      .eq("id", HANGER_ID)
      .single();
    if (he) throw he;

    const { data: items, error: ie } = await sb
      .from("inventory_items")
      .select("*")
      .eq("hanger_id", HANGER_ID)
      .order("order_index", { ascending: true });
    if (ie) throw ie;

    HANGER  = hanger;
    SESSION = hanger.inventory_sessions || {};
    const loaded = items || [];
    CURRENT_ITEMS = loaded;
    currentCategory = loaded.length ? (loaded[loaded.length - 1].category || "") : "";
    unphotographedCount = loaded.filter(it => !it.photo_url).length;
    render(loaded);
    if (SESSION.status === "pending") { loadSessionBrands(); loadTodayBrands(); }
  } catch (e) {
    showError("행거 로드 실패: " + e.message);
  }
}

function render(items) {
  itemCount = items.length;
  const isPending = SESSION.status === "pending";
  const isMine   = !HANGER.submitted_by || HANGER.submitted_by === getMyName();
  const canEdit  = isPending && isMine;

  const backWrap = document.getElementById("back-btn-wrap");
  const titleEl  = document.getElementById("page-title");
  if (backWrap) backWrap.innerHTML = `
    <a href="session.html?id=${encodeURIComponent(SESSION.id || "")}" class="back-btn">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" width="22" height="22"><polyline points="15 18 9 12 15 6"/></svg>
    </a>`;
  if (titleEl) titleEl.textContent = `행거 ${HANGER.hanger_number}`;

  const usedCategories = [...new Set(items.map(it => it.category).filter(Boolean))];
  let html = `
    <div class="flex mb16" style="gap:8px; flex-wrap:wrap">
      <span class="${SESSION.location === "온라인" ? "tag-online" : "tag-offline"}">${SESSION.location === "온라인" ? "온라인" : "공동물류"}</span>
      ${usedCategories.length ? `<span class="tag-offline">${escapeHtml(usedCategories.join(" · "))}</span>` : ""}
      ${HANGER.submitted_by ? `<span class="muted text-xs" style="align-self:center">· ${escapeHtml(HANGER.submitted_by)}</span>` : ""}
    </div>
  `;

  if (!isPending) {
    html += `<div class="card card-success" style="margin-bottom:16px">
      <span class="success">✓ 이 세션은 승인되었습니다. 편집 불가.</span>
    </div>`;
  } else if (!isMine) {
    html += `<div class="card" style="border-color:#334155; background:#0f172a; margin-bottom:16px">
      <span style="color:#94a3b8">🔒 ${escapeHtml(HANGER.submitted_by)}만 편집할 수 있는 행거입니다.</span>
    </div>`;
  } else {
    // C 카테고리(균일가 저가 상품, 6,800/9,800원)는 브랜드·사진 데이터를 안 받음 — 가격+수량만 빠르게 입력
    const isBulkC = currentCategory.trim().toUpperCase() === "C";
    html += `
      <div class="card">
        <div class="form-group" style="margin-bottom:10px">
          <label>카테고리</label>
          <select id="category-select">
            <option value="">카테고리 선택</option>
            ${CATEGORIES.map(c => `<option value="${escapeHtml(c)}"${c === currentCategory ? " selected" : ""}>${escapeHtml(categoryLabel(c))}</option>`).join("")}
          </select>
        </div>
        ${isBulkC ? "" : `
        <div id="brand-chips" style="display:flex; flex-wrap:nowrap; gap:6px; margin-bottom:8px; overflow-x:auto; padding-bottom:2px"></div>
        <div style="position:relative; margin-bottom:10px">
          <input type="text" id="brand-input" placeholder="브랜드명" autocomplete="off">
          <div id="brand-dropdown" style="display:none; position:absolute; top:100%; left:0; right:0; background:#1e293b; border:1px solid #334155; border-radius:8px; margin-top:4px; z-index:100; overflow:hidden; box-shadow:0 4px 16px rgba(0,0,0,.4)"></div>
        </div>
        <button type="button" class="btn btn-outline btn-sm" id="no-brand-btn" style="margin-bottom:10px">브랜드 없음 (Vintage)</button>`}
        <div class="add-row">
          <input type="number" id="price-input" placeholder="가격 입력" inputmode="decimal" autocomplete="off">
          <input type="number" id="count-input" value="1" min="1" max="50" inputmode="numeric" title="수량">
          <button id="add-btn">+</button>
        </div>
        ${isBulkC ? "" : `
        <div class="flex mt8">
          <button type="button" class="btn btn-outline btn-sm" id="ref-btn">📊 가격 참조</button>
        </div>
        <div id="price-ref-panel" class="price-ref-panel">
          <div id="price-ref-content" class="text-xs muted">브랜드 입력 후 조회</div>
        </div>`}
        <div class="text-xs muted mt8" style="text-align:center; line-height:1.7">
          가격 입력 후 <strong>+</strong> 또는 <strong>엔터</strong>로 추가
          &nbsp;·&nbsp; 1000 미만은 자동 ×1000
        </div>
      </div>

      ${isBulkC ? "" : `
      <a id="bulk-photo-btn" href="bulk-photo.html?id=${encodeURIComponent(HANGER_ID)}"
         class="btn btn-outline btn-block" style="margin-bottom:12px">${bulkPhotoLabel()}</a>`}
    `;
  }

  html += `
    <div class="total-bar">
      <span class="muted text-sm">아이템</span>
      <span id="item-count" style="font-weight:700; font-size:16px">${itemCount}개</span>
    </div>
    <div class="card" id="item-list">
      ${items.length === 0 ? '<div class="empty" id="empty-msg">아직 아이템이 없습니다</div>' :
        items.map((item, i) => itemRowHtml(item, i + 1, canEdit)).join("")}
    </div>
  `;

  if (canEdit) {
    html += `<div class="mt16">
      <button id="submit-btn" class="btn btn-success btn-block">행거 제출하기</button>
    </div>`;
  }

  document.getElementById("content").innerHTML = html;
  document.getElementById("item-list").addEventListener("click", e => {
    if (e.target.classList.contains("photo-preview")) viewPhoto(e.target.src);
  });
  if (canEdit) bindHandlers();
}

function bulkPhotoLabel() {
  if (unphotographedCount === 0 && itemCount > 0) return "📷 일괄 촬영 ✓ 완료";
  if (unphotographedCount > 0) return `📷 일괄 촬영 (${unphotographedCount}장 미촬영)`;
  return "📷 일괄 촬영";
}

function updateBulkPhotoBtn() {
  const btn = document.getElementById("bulk-photo-btn");
  if (btn) btn.textContent = bulkPhotoLabel();
}

function itemRowHtml(item, num, canDel) {
  const meta = [item.brand, item.category ? categoryLabel(item.category) : ""].filter(Boolean).join(" · ");
  return `<div class="item-row" id="item-${escapeHtml(item.id)}" data-has-photo="${item.photo_url ? '1' : '0'}">
    <span class="item-num">${num}</span>
    <div class="item-info">
      <div class="item-price">₩${(item.price || 0).toLocaleString()}</div>
      ${meta ? `<div class="item-brand">${escapeHtml(meta)}</div>` : ""}
      ${item.photo_url ? `<img src="${escapeHtml(item.photo_url)}" class="photo-preview" alt="사진">` : ""}
    </div>
    ${canDel ? `<button class="edit-btn" data-id="${escapeHtml(item.id)}">✎</button>` : ""}
    ${canDel ? `<button class="del-btn" data-id="${escapeHtml(item.id)}">×</button>` : ""}
  </div>`;
}

function openEditItemModal(item) {
  const overlay = document.createElement("div");
  overlay.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box";
  overlay.innerHTML = `
    <div style="background:#1e293b;border-radius:14px;padding:24px 20px;max-width:340px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.5)">
      <div style="color:#f1f5f9;font-size:16px;font-weight:700;margin-bottom:16px">아이템 수정</div>
      <div style="text-align:center; margin-bottom:16px">
        <img id="edit-photo-preview" src="${escapeHtml(item.photo_url || "")}" style="max-width:140px; max-height:140px; border-radius:8px; border:1px solid #334155; object-fit:cover; ${item.photo_url ? "" : "display:none"}" alt="사진">
        <div id="edit-photo-empty" style="${item.photo_url ? "display:none" : ""}; color:#64748b; font-size:13px; padding:24px 0">사진 없음</div>
        <div>
          <button type="button" id="edit-photo-btn" class="btn btn-outline btn-sm" style="margin-top:8px">${item.photo_url ? "📷 재촬영" : "📷 촬영"}</button>
        </div>
        <input type="file" accept="image/*" capture="environment" id="edit-photo-file" style="display:none">
      </div>
      <div class="form-group" style="margin-bottom:10px">
        <label>카테고리</label>
        <select id="edit-category">
          ${CATEGORIES.map(c => `<option value="${escapeHtml(c)}"${c === item.category ? " selected" : ""}>${escapeHtml(categoryLabel(c))}</option>`).join("")}
        </select>
      </div>
      <div class="form-group" style="margin-bottom:10px">
        <label>브랜드</label>
        <input type="text" id="edit-brand" value="${escapeHtml(item.brand || "")}" autocomplete="off">
      </div>
      <div class="form-group" style="margin-bottom:16px">
        <label>가격</label>
        <input type="number" id="edit-price" value="${item.price || 0}" inputmode="decimal">
      </div>
      <div style="display:flex;gap:8px">
        <button id="_edit-cancel" style="flex:1;padding:11px;background:#334155;border:none;border-radius:8px;color:#94a3b8;font-size:14px;cursor:pointer">취소</button>
        <button id="_edit-save" style="flex:1;padding:11px;background:#3b82f6;border:none;border-radius:8px;color:#fff;font-size:14px;font-weight:600;cursor:pointer">저장</button>
      </div>
    </div>`;
  document.body.appendChild(overlay);
  const close = () => overlay.remove();
  overlay.querySelector("#_edit-cancel").addEventListener("click", close);
  overlay.addEventListener("click", e => { if (e.target === overlay) close(); });

  const photoBtn  = overlay.querySelector("#edit-photo-btn");
  const photoFile = overlay.querySelector("#edit-photo-file");
  photoBtn.addEventListener("click", () => photoFile.click());
  photoFile.addEventListener("change", async e => {
    const file = e.target.files[0];
    e.target.value = "";
    if (!file) return;
    photoBtn.disabled = true; photoBtn.textContent = "⏳ 업로드 중…";
    const hadPhoto = !!item.photo_url;
    try {
      const compressed = await compressImage(file);
      const url = await sbUploadPhoto(HANGER_ID, compressed);
      const { error } = await sb.from("inventory_items").update({ photo_url: url }).eq("id", item.id);
      if (error) throw error;
      item.photo_url = url;
      if (!hadPhoto) unphotographedCount = Math.max(0, unphotographedCount - 1);
      const img   = overlay.querySelector("#edit-photo-preview");
      const empty = overlay.querySelector("#edit-photo-empty");
      img.src = url; img.style.display = "";
      empty.style.display = "none";
      render(CURRENT_ITEMS);
    } catch (err) {
      showError("사진 업로드 실패: " + err.message);
    } finally {
      photoBtn.disabled = false;
      photoBtn.textContent = item.photo_url ? "📷 재촬영" : "📷 촬영";
    }
  });

  overlay.querySelector("#_edit-save").addEventListener("click", async () => {
    const saveBtn = overlay.querySelector("#_edit-save");
    const category = overlay.querySelector("#edit-category").value;
    const brand = overlay.querySelector("#edit-brand").value.trim();
    let price = parseFloat(overlay.querySelector("#edit-price").value || "0");
    if (price < 1000) price = Math.round(price * 1000);
    price = Math.round(price);

    saveBtn.disabled = true; saveBtn.textContent = "저장 중…";
    try {
      const updates = { category: category || null, brand: brand || null, price };
      const { error } = await sb.from("inventory_items").update(updates).eq("id", item.id);
      if (error) throw error;
      Object.assign(item, updates);
      close();
      render(CURRENT_ITEMS);
    } catch (e) {
      saveBtn.disabled = false; saveBtn.textContent = "저장";
      showError("수정 실패: " + e.message);
    }
  });
}

function bindHandlers() {
  const priceEl = document.getElementById("price-input");
  document.getElementById("add-btn").addEventListener("click", addItem);
  priceEl.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); addItem(); } });

  document.getElementById("category-select")?.addEventListener("change", e => {
    currentCategory = e.target.value;
    render(CURRENT_ITEMS);
  });
  document.getElementById("ref-btn")?.addEventListener("click", togglePriceRef);
  document.getElementById("brand-input")?.addEventListener("input", onBrandInput);
  document.getElementById("brand-input")?.addEventListener("blur", () => {
    setTimeout(hideBrandDropdown, 150);
  });
  document.getElementById("no-brand-btn")?.addEventListener("click", () => {
    const brandEl = document.getElementById("brand-input");
    brandEl.value = "Vintage";
    hideBrandDropdown();
    document.getElementById("price-input").focus();
  });

  document.getElementById("submit-btn").addEventListener("click", submitHanger);
  document.getElementById("item-list").addEventListener("click", e => {
    if (e.target.classList.contains("del-btn")) deleteItem(e.target.dataset.id, e.target);
    if (e.target.classList.contains("edit-btn")) {
      const item = CURRENT_ITEMS.find(it => it.id === e.target.dataset.id);
      if (item) openEditItemModal(item);
    }
  });

  setTimeout(() => priceEl.focus(), 100);
}

async function loadSessionBrands() {
  try {
    const { data } = await sb
      .from("inventory_items")
      .select("brand")
      .eq("session_id", SESSION.id)
      .not("brand", "is", null);
    const unique = [...new Set((data || []).map(it => it.brand).filter(Boolean))];
    sessionBrands = unique;
    renderBrandChips();
  } catch (_) {}
}

async function loadTodayBrands() {
  try {
    const { data } = await sb
      .from("inventory_items")
      .select("brand, inventory_sessions!inner(session_date)")
      .eq("inventory_sessions.session_date", localDateStr())
      .not("brand", "is", null);
    todayBrands = [...new Set((data || []).map(it => it.brand).filter(Boolean))];
  } catch (_) {}
}

function renderBrandChips() {
  const el = document.getElementById("brand-chips");
  if (!el) return;
  el.innerHTML = sessionBrands.slice(0, 20).map(b =>
    `<button type="button" style="background:#0f172a; border:1px solid #334155; border-radius:99px; padding:4px 12px; font-size:12px; color:#94a3b8; cursor:pointer; white-space:nowrap; flex-shrink:0" data-brand="${escapeHtml(b)}">${escapeHtml(b)}</button>`
  ).join("");
  el.querySelectorAll("button").forEach(btn => {
    btn.addEventListener("click", () => {
      document.getElementById("brand-input").value = btn.dataset.brand;
      hideBrandDropdown();
    });
  });
}

function onBrandInput() {
  if (refVisible) {
    clearTimeout(refDebounceTimer);
    refDebounceTimer = setTimeout(loadPriceRef, 600);
  }
  const q = (document.getElementById("brand-input").value || "").trim();
  clearTimeout(brandDropdownTimer);
  if (q.length < 2) { hideBrandDropdown(); return; }
  brandDropdownTimer = setTimeout(() => showBrandDropdown(q), 300);
}

async function showBrandDropdown(q) {
  const [{ data: prefixData }, { data: containsData }] = await Promise.all([
    sb.from("brand_master").select("name").ilike("name", `${q}%`).order("name").limit(8),
    sb.from("brand_master").select("name").ilike("name", `%${q}%`).order("name").limit(8),
  ]);
  const lowerQ = q.toLowerCase();
  const masterPrefix = (prefixData || []).map(it => it.name).filter(Boolean);
  const masterContains = (containsData || []).map(it => it.name).filter(Boolean);
  const todayPrefix = todayBrands.filter(b => b.toLowerCase().startsWith(lowerQ));
  const todayContains = todayBrands.filter(b => b.toLowerCase().includes(lowerQ) && !b.toLowerCase().startsWith(lowerQ));

  const seen = new Set();
  const brands = [];
  for (const b of [...masterPrefix, ...todayPrefix, ...masterContains, ...todayContains]) {
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
    `<div data-brand="${escapeHtml(b)}" style="padding:10px 14px; font-size:14px; color:#e2e8f0; cursor:pointer; border-bottom:1px solid #0f172a">${escapeHtml(b)}</div>`
  ).join("");
  dd.style.display = "block";
  dd.querySelectorAll("div").forEach(item => {
    item.addEventListener("mousedown", () => {
      document.getElementById("brand-input").value = item.dataset.brand;
      hideBrandDropdown();
    });
  });
}

function hideBrandDropdown() {
  const dd = document.getElementById("brand-dropdown");
  if (dd) dd.style.display = "none";
}

function togglePriceRef() {
  const brand = (document.getElementById("brand-input").value || "").trim();
  if (!brand) {
    document.getElementById("brand-input").focus();
    document.getElementById("brand-input").placeholder = "브랜드를 먼저 입력하세요";
    return;
  }
  refVisible = !refVisible;
  document.getElementById("price-ref-panel").classList.toggle("open", refVisible);
  if (refVisible) loadPriceRef();
}

async function loadPriceRef() {
  const brand   = document.getElementById("brand-input").value.trim();
  const content = document.getElementById("price-ref-content");
  if (!brand) { content.textContent = "브랜드를 입력하세요"; return; }
  content.textContent = "⏳ 로딩…";
  try {
    const { data, error } = await sb
      .from("inventory_items")
      .select("price")
      .ilike("brand", brand)
      .eq("category", currentCategory)
      .not("price", "is", null)
      .gt("price", 0)
      .order("created_at", { ascending: false })
      .limit(10);
    if (error) throw error;
    if (!data || data.length === 0) {
      content.textContent = `${brand} ${currentCategory} 입고 내역 없음`;
      return;
    }
    const avg = Math.round(data.reduce((s, it) => s + it.price, 0) / data.length);
    content.innerHTML = `
      <div style="text-align:center; padding:4px 0">
        <div style="font-size:22px; font-weight:800; color:var(--brand-primary)">₩${avg.toLocaleString()}</div>
        <div style="font-size:11px; color:var(--fg-tertiary); margin-top:4px">최근 ${data.length}건 평균</div>
      </div>`;
  } catch (e) {
    content.textContent = "오류: " + e.message;
  }
}

async function addItem() {
  const priceEl = document.getElementById("price-input");
  const brandEl = document.getElementById("brand-input");
  const countEl = document.getElementById("count-input");
  const priceRaw = priceEl.value.trim();
  const count    = Math.max(1, parseInt(countEl.value || "1", 10) || 1);
  if (!currentCategory) { showError("카테고리를 선택하세요"); return; }
  if (!priceRaw) { priceEl.focus(); return; }

  let price = parseFloat(priceRaw);
  if (price < 1000) price = Math.round(price * 1000);
  price = Math.round(price);

  const brand = brandEl ? brandEl.value.trim() : "";
  const addBtn = document.getElementById("add-btn");
  addBtn.disabled = true; addBtn.textContent = "…";

  try {
    const rows = Array.from({ length: count }, (_, i) => ({
      hanger_id: HANGER_ID, session_id: SESSION.id, price, brand: brand || null,
      order_index: itemCount + i,
      location: SESSION.location || null,
      category: currentCategory || null,
    }));
    const { data: newItems, error } = await sb.from("inventory_items").insert(rows).select();
    if (error) throw error;

    if (count > 1) {
      priceEl.value = ""; countEl.value = "1";
      load();
      return;
    }
    prependItem(newItems[0]);
    if (brand && !sessionBrands.includes(brand)) {
      sessionBrands.unshift(brand);
      renderBrandChips();
    }
    if (brand && !todayBrands.includes(brand)) todayBrands.unshift(brand);
    priceEl.value = ""; countEl.value = "1";
    if (brandEl) brandEl.value = "";
    hideBrandDropdown();
    priceEl.focus();
  } catch (e) {
    showError(e.message);
  } finally {
    addBtn.disabled = false; addBtn.textContent = "+";
  }
}

function prependItem(item) {
  CURRENT_ITEMS.push(item);
  itemCount++;
  unphotographedCount++;
  document.getElementById("item-count").textContent = itemCount + "개";
  document.getElementById("empty-msg")?.remove();
  const list = document.getElementById("item-list");
  const div  = document.createElement("div");
  div.innerHTML = itemRowHtml(item, 1, true);
  list.insertBefore(div.firstElementChild, list.firstChild);
  renumber();
  updateBulkPhotoBtn();
}

function renumber() {
  document.querySelectorAll("#item-list .item-row").forEach((row, i) => {
    const num = row.querySelector(".item-num");
    if (num) num.textContent = i + 1;
  });
}

async function deleteItem(itemId, btn) {
  if (!await appConfirm("삭제하시겠습니까?")) return;
  btn.textContent = "…"; btn.disabled = true;
  const row = document.getElementById(`item-${itemId}`);
  const hadPhoto = row?.dataset.hasPhoto === "1";
  try {
    const { error } = await sb.from("inventory_items").delete().eq("id", itemId);
    if (error) throw error;
    CURRENT_ITEMS = CURRENT_ITEMS.filter(it => it.id !== itemId);
    row?.remove();
    itemCount = Math.max(0, itemCount - 1);
    if (!hadPhoto) unphotographedCount = Math.max(0, unphotographedCount - 1);
    document.getElementById("item-count").textContent = itemCount + "개";
    renumber();
    updateBulkPhotoBtn();
    if (itemCount === 0) {
      document.getElementById("item-list").innerHTML =
        '<div class="empty" id="empty-msg">아직 아이템이 없습니다</div>';
    }
  } catch (e) {
    showError("삭제 실패: " + e.message);
    btn.textContent = "×"; btn.disabled = false;
  }
}


async function submitHanger() {
  if (!await appConfirm("이 행거를 제출하시겠습니까?")) return;
  try {
    const { error } = await sb
      .from("inventory_hangers")
      .update({ submitted_at: new Date().toISOString() })
      .eq("id", HANGER_ID);
    if (error) throw error;
    location.href = "session.html?id=" + encodeURIComponent(SESSION.id);
  } catch (e) {
    showError("제출 실패: " + e.message);
  }
}

load();
