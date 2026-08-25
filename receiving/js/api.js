function fmtDate(d) {
  if (!d) return "";
  return d.slice(0, 10).replace(/-/g, ".");
}

function fmtPrice(p) {
  return p != null ? "₩" + Number(p).toLocaleString() : "";
}

function getParam(name) {
  return new URLSearchParams(location.search).get(name) || "";
}

function showError(msg) {
  const el = document.getElementById("error-msg");
  if (el) { el.textContent = msg; el.style.display = "block"; }
  else if (typeof appAlert === "function") appAlert(msg); else alert(msg);
}

function clearError() {
  const el = document.getElementById("error-msg");
  if (el) { el.textContent = ""; el.style.display = "none"; }
}

function escapeHtml(s) {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

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
