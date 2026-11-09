// 사무 업무 가이드(index.html 보기·edit.html 편집) 공용.
// 권한은 서버(RLS: 읽기=로그인 직원, 쓰기=is_admin())가 강제한다. 화면의 role 체크는 버튼을 숨길 뿐이다.
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// 평문 본문: 이스케이프 후 URL만 링크로, 줄바꿈은 CSS(white-space: pre-wrap)가 처리
const linkify = (s) => esc(s).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
const errMsg = (e) => e?.message || String(e);
const BUCKET = 'office-files';

function toast(msg, isErr) {
  let t = document.getElementById('toast');
  if (!t) { t = document.createElement('div'); t.id = 'toast'; document.body.appendChild(t); }
  t.textContent = msg;
  t.className = 'show' + (isErr ? ' err' : '');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { t.className = ''; }, 2600);
}

async function waitProfile() {
  for (let i = 0; i < 50 && window.MIU_PROFILE === undefined; i++) await new Promise((r) => setTimeout(r, 100));
  return window.MIU_PROFILE;
}

const fmtSize = (n) => (n == null ? '' : n >= 1048576 ? `${(n / 1048576).toFixed(1)}MB` : `${Math.max(1, Math.round(n / 1024))}KB`);

// 비공개 버킷이라 보여줄 때마다 임시 서명 URL을 받는다(1시간). 이미지는 한 번에, 다운로드는 원래 파일 이름으로.
async function signedUrls(paths) {
  if (!paths.length) return new Map();
  const { data, error } = await window.sb.storage.from(BUCKET).createSignedUrls(paths, 3600);
  if (error) throw error;
  return new Map(data.map((r) => [r.path, r.signedUrl]));
}
async function downloadUrl(path, name) {
  const { data, error } = await window.sb.storage.from(BUCKET).createSignedUrl(path, 300, { download: name });
  if (error) throw error;
  return data.signedUrl;
}
