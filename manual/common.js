// 매장 업무 매뉴얼(index.html)·관리자 화면(admin.html) 공용.
// 권한은 서버(is_store_staff / is_store_manager)가 강제한다. 여기서는 화면 분기용으로 store_manual_role()만 읽는다.
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// 평문 본문: 이스케이프 후 URL만 링크로, 줄바꿈은 CSS(white-space: pre-wrap)가 처리
const linkify = (s) => esc(s).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
const DOW = ['일', '월', '화', '수', '목', '금', '토'];
const dow = (iso) => DOW[new Date(iso + 'T00:00:00Z').getUTCDay()];
const mdw = (iso) => { const [, m, d] = iso.split('-'); return `${+m}/${+d}(${dow(iso)})`; };
const addDays = (iso, n) => new Date(new Date(iso + 'T00:00:00Z').getTime() + n * 86400000).toISOString().slice(0, 10);
const hhmm = (ts) => new Date(ts).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Asia/Seoul' });
// 요일 번호는 서버(isodow)와 같은 1=월 … 7=일
const isoDow = (iso) => new Date(iso + 'T00:00:00Z').getUTCDay() || 7;
const weekdaysLabel = (wd) => (wd ? wd.slice().sort((a, b) => a - b).map((n) => DOW[n % 7]).join('·') : '');
// 이 항목이 그 날짜·매장의 체크리스트에 들어가는가(매장 전용/공통 + 요일 조건). 활성 여부는 호출하는 쪽이 따로 본다.
const appliesOn = (item, store, date) => (item.store === null || item.store === store)
  && (!item.weekdays || item.weekdays.includes(isoDow(date)));

// 성수 = 본점(근무자 항상 1명). 그 밖의 활성 위치 = 키오스크(무인 팝업) 매장이고, 철수하면 위치가 비활성이 되어 목록에서 빠진다.
// 매장 추가/철수는 허브 기존 흐름(통합 관리 → 매장 추가 / 매장 현황판 → 철수완료)이 `locations`를 바꾸는 것이 전부다.
// 매장이 아닌 위치만 여기서 뺀다(물류·온라인·폐기·재봉합). 새로 생기는 비매장 위치가 있으면 이 목록에 추가.
const HEAD_STORE = '성수';
const NON_STORE = ['공동물류', '온라인', '폐기', '재봉합부천', '재봉합성수'];
const storeLabel = (s) => (s === HEAD_STORE ? '성수 본점' : s);
async function loadStores() {
  const { data, error } = await window.sb.from('locations').select('name').eq('is_active', true).order('name');
  if (error) throw error;
  const names = data.map((r) => r.name).filter((n) => !NON_STORE.includes(n));
  return [...names.filter((n) => n === HEAD_STORE), ...names.filter((n) => n !== HEAD_STORE)];
}

// 오늘 날짜는 기기 시계가 아니라 서버(KST) 기준 — 기록하는 쪽(RPC)과 같은 값을 써야 한다
async function serverToday() {
  const { data, error } = await window.sb.rpc('store_today');
  if (error) throw error;
  return data;
}
async function manualRole() {
  const { data, error } = await window.sb.rpc('store_manual_role');
  if (error) throw error;
  return data; // 'manager' | 'staff' | null
}

function toast(msg, isErr) {
  let t = document.getElementById('toast');
  if (!t) { t = document.createElement('div'); t.id = 'toast'; document.body.appendChild(t); }
  t.textContent = msg;
  t.className = 'show' + (isErr ? ' err' : '');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { t.className = ''; }, 2600);
}
const errMsg = (e) => e?.message || String(e);
