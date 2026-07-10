const USER_KEY = "archive-review-user";

let photos = [];       // [{id, public_url, ratings: [{employee_name, score, feedback}]}]
let currentUser = localStorage.getItem(USER_KEY) || "";
let activePhotoId = null;
let selectedScore = null;

function initNameGate() {
  const grid = document.getElementById("name-grid");
  grid.innerHTML = EMPLOYEES.map(
    (name) => `<button class="name-btn" onclick="selectUser('${name}')">${name}</button>`
  ).join("");
}

function selectUser(name) {
  currentUser = name;
  localStorage.setItem(USER_KEY, name);
  document.getElementById("name-gate").style.display = "none";
  document.getElementById("current-user").textContent = name;
  loadData();
}

function changeUser() {
  document.getElementById("name-gate").style.display = "flex";
}

function photoStats(photo) {
  const count = photo.ratings.length;
  const avg = count ? photo.ratings.reduce((s, r) => s + r.score, 0) / count : null;
  return { avg, count };
}

function sortPhotos() {
  photos.sort((a, b) => {
    const sa = photoStats(a).avg;
    const sb = photoStats(b).avg;
    if (sa === null && sb === null) return 0;
    if (sa === null) return 1;
    if (sb === null) return -1;
    return sb - sa;
  });
}

function renderGrid() {
  sortPhotos();
  const grid = document.getElementById("grid");
  const empty = document.getElementById("empty");
  if (!photos.length) {
    grid.innerHTML = "";
    empty.style.display = "block";
    return;
  }
  empty.style.display = "none";
  grid.innerHTML = photos
    .map((p) => {
      const { avg, count } = photoStats(p);
      const done = p.ratings.some((r) => r.employee_name === currentUser);
      return `
    <div class="card" onclick="openSheet('${p.id}')">
      <div class="card-img-wrap">
        <img src="${p.public_url}" loading="lazy">
        ${done ? '<div class="card-done">✓ 평가완료</div>' : ""}
      </div>
      <div class="card-meta">
        ${avg !== null ? `<span class="card-score">${avg.toFixed(1)}</span>` : '<span class="card-score none">미평가</span>'}
        <span class="card-count">${count}명</span>
      </div>
    </div>`;
    })
    .join("");
}

function openSheet(photoId) {
  activePhotoId = photoId;
  const photo = photos.find((p) => p.id === photoId);
  const mine = photo.ratings.find((r) => r.employee_name === currentUser);
  selectedScore = mine ? mine.score : null;

  document.getElementById("sheet-img").src = photo.public_url;
  document.getElementById("feedback-input").value = mine ? mine.feedback || "" : "";

  renderScoreRow();
  renderSheetStats();
  renderRatingList();

  document.getElementById("overlay").classList.add("open");
}

function renderScoreRow() {
  const row = document.getElementById("score-row");
  row.innerHTML = Array.from({ length: 10 }, (_, i) => i + 1)
    .map((n) => `<div class="score-btn ${n === selectedScore ? "selected" : ""}" onclick="pickScore(${n})">${n}</div>`)
    .join("");
}

function pickScore(n) {
  selectedScore = n;
  renderScoreRow();
}

function renderSheetStats() {
  const photo = photos.find((p) => p.id === activePhotoId);
  const { avg, count } = photoStats(photo);
  document.getElementById("sheet-avg").textContent = avg !== null ? avg.toFixed(1) : "-";
  document.getElementById("sheet-count").textContent = count;
}

function renderRatingList() {
  const photo = photos.find((p) => p.id === activePhotoId);
  const list = document.getElementById("rating-list");
  if (!photo.ratings.length) {
    list.innerHTML = '<div class="rating-item">아직 평가가 없습니다.</div>';
    return;
  }
  list.innerHTML = photo.ratings
    .slice()
    .sort((a, b) => a.employee_name.localeCompare(b.employee_name))
    .map(
      (r) => `
    <div class="rating-item">
      <div class="rating-item-top">
        <span class="rating-item-name">${r.employee_name}</span>
        <span class="rating-item-score">${r.score}점</span>
      </div>
      ${r.feedback ? `<div class="rating-item-feedback">${escapeHtml(r.feedback)}</div>` : ""}
    </div>`
    )
    .join("");
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

function closeSheet() {
  document.getElementById("overlay").classList.remove("open");
  activePhotoId = null;
}

async function submitRating() {
  if (selectedScore === null) {
    alert("점수를 선택해주세요.");
    return;
  }
  const btn = document.getElementById("submit-btn");
  btn.disabled = true;
  btn.textContent = "제출 중...";

  const feedback = document.getElementById("feedback-input").value.trim();
  const { error } = await sb.from("photo_ratings").upsert(
    {
      photo_id: activePhotoId,
      employee_name: currentUser,
      score: selectedScore,
      feedback: feedback || null,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "photo_id,employee_name" }
  );

  btn.disabled = false;
  btn.textContent = "제출";

  if (error) {
    alert("제출 실패: " + error.message);
    return;
  }

  const photo = photos.find((p) => p.id === activePhotoId);
  const idx = photo.ratings.findIndex((r) => r.employee_name === currentUser);
  const newRating = { employee_name: currentUser, score: selectedScore, feedback: feedback || null };
  if (idx >= 0) photo.ratings[idx] = newRating;
  else photo.ratings.push(newRating);

  renderSheetStats();
  renderRatingList();
  renderGrid();
}

async function loadData() {
  const [{ data: photoRows, error: photoErr }, { data: ratingRows, error: ratingErr }] = await Promise.all([
    sb.from("archive_photos").select("id, public_url").order("uploaded_at", { ascending: false }),
    sb.from("photo_ratings").select("photo_id, employee_name, score, feedback"),
  ]);

  if (photoErr || ratingErr) {
    alert("데이터 로드 실패: " + ((photoErr || ratingErr).message));
    return;
  }

  photos = photoRows.map((p) => ({
    id: p.id,
    public_url: p.public_url,
    ratings: ratingRows.filter((r) => r.photo_id === p.id),
  }));

  renderGrid();
}

initNameGate();
if (currentUser) {
  document.getElementById("name-gate").style.display = "none";
  document.getElementById("current-user").textContent = currentUser;
  loadData();
} else {
  document.getElementById("current-user").textContent = "이름 선택";
}
