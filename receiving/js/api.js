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
