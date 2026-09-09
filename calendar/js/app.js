const ADMIN_PIN = '1357';

const HOLIDAYS = {
  // 2025
  '2025-01-01': '신정',
  '2025-01-28': '설날연휴',
  '2025-01-29': '설날',
  '2025-01-30': '설날연휴',
  '2025-03-01': '삼일절',
  '2025-05-05': '어린이날',
  '2025-05-06': '대체공휴일',
  '2025-06-06': '현충일',
  '2025-08-15': '광복절',
  '2025-10-03': '개천절',
  '2025-10-05': '추석연휴',
  '2025-10-06': '추석',
  '2025-10-07': '추석연휴',
  '2025-10-08': '대체공휴일',
  '2025-10-09': '한글날',
  '2025-12-25': '성탄절',
  // 2026
  '2026-01-01': '신정',
  '2026-02-16': '설날연휴',
  '2026-02-17': '설날',
  '2026-02-18': '설날연휴',
  '2026-03-01': '삼일절',
  '2026-05-05': '어린이날',
  '2026-05-24': '부처님오신날',
  '2026-06-06': '현충일',
  '2026-08-15': '광복절',
  '2026-09-24': '추석연휴',
  '2026-09-25': '추석',
  '2026-09-26': '추석연휴',
  '2026-10-03': '개천절',
  '2026-10-09': '한글날',
  '2026-12-25': '성탄절',
};

const EVENT_TYPES = [
  { key: '팝업셋업',  color: '#3b82f6' },
  { key: '철수',      color: '#8b5cf6' },
  { key: '행사',      color: '#f59e0b' },
  { key: '재고조사',  color: '#06b6d4' },
  { key: '플리마켓',  color: '#22c55e' },
  { key: '기타',      color: '#989BA2' },
];

function typeColor(type) {
  return (EVENT_TYPES.find(t => t.key === type) || EVENT_TYPES[EVENT_TYPES.length - 1]).color;
}

let currentYear, currentMonth;
let allEvents = [];
let adminUnlocked = false;

// ── PIN ──────────────────────────────────────────────
let pinBuffer = '';
let pinCallback = null;

function requireAdmin(callback) {
  if (adminUnlocked) { callback(); return; }
  pinBuffer = '';
  pinCallback = callback;
  document.getElementById('pin-overlay').style.display = 'flex';
  renderPinDots();
}

function pinPress(digit) {
  if (pinBuffer.length >= 4) return;
  pinBuffer += digit;
  renderPinDots();
  if (pinBuffer.length === 4) setTimeout(checkPin, 150);
}

function pinDel() {
  pinBuffer = pinBuffer.slice(0, -1);
  renderPinDots();
  document.getElementById('pin-error').textContent = '';
}

function renderPinDots() {
  document.querySelectorAll('.pin-dot').forEach((d, i) => d.classList.toggle('filled', i < pinBuffer.length));
}

function checkPin() {
  if (pinBuffer === ADMIN_PIN) {
    adminUnlocked = true;
    closePinModal();
    if (pinCallback) pinCallback();
  } else {
    document.getElementById('pin-error').textContent = '핀 번호가 틀렸습니다';
    pinBuffer = '';
    renderPinDots();
  }
}

function closePinModal() {
  document.getElementById('pin-overlay').style.display = 'none';
  pinBuffer = '';
}

// ── 데이터 로드 ──────────────────────────────────────
async function loadEvents(year, month) {
  const from = `${year}-${String(month).padStart(2,'0')}-01`;
  const lastDay = new Date(year, month, 0).getDate();
  const to   = `${year}-${String(month).padStart(2,'0')}-${String(lastDay).padStart(2,'0')}`;

  const { data, error } = await sb
    .from('calendar_events')
    .select('*')
    .gte('event_date', from)
    .lte('event_date', to)
    .order('event_date');

  if (error) { console.error(error); return []; }
  return data || [];
}

// ── 캘린더 렌더 ──────────────────────────────────────
async function renderCalendar(year, month) {
  currentYear = year;
  currentMonth = month;

  const MONTH_KO = ['1월','2월','3월','4월','5월','6월','7월','8월','9월','10월','11월','12월'];
  document.getElementById('cal-year').textContent = `${year}년`;

  // 월별 일러스트 교체
  const mm = String(month).padStart(2, '0');
  const illoImg = document.getElementById('illo-img');
  const illoFallback = document.getElementById('illo-fallback');
  const illoBadge = document.getElementById('illo-badge-tag');
  if (illoImg) {
    illoImg.style.display = 'block';
    illoImg.classList.remove('loaded');
    illoImg.src = `photo/${month}월/image.png`;
    if (illoBadge) illoBadge.textContent = MONTH_KO[month - 1];
    illoImg.onload = () => {
      illoImg.classList.add('loaded');
      if (illoFallback) illoFallback.style.display = 'none';
    };
    illoImg.onerror = () => {
      illoImg.style.display = 'none';
      if (illoFallback) illoFallback.style.display = 'flex';
    };
  }

  allEvents = await loadEvents(year, month);

  const firstDay = new Date(year, month - 1, 1).getDay();
  const lastDate = new Date(year, month, 0).getDate();

  const grid = document.getElementById('cal-grid');
  grid.innerHTML = '';

  // 요일 헤더
  ['일','월','화','수','목','금','토'].forEach((d, i) => {
    const el = document.createElement('div');
    el.className = 'cal-dow' + (i === 0 ? ' sun' : i === 6 ? ' sat' : '');
    el.textContent = d;
    grid.appendChild(el);
  });

  // 앞 빈칸
  for (let i = 0; i < firstDay; i++) {
    grid.appendChild(Object.assign(document.createElement('div'), { className: 'cal-cell empty' }));
  }

  const todayStr = toDateStr(new Date());

  for (let d = 1; d <= lastDate; d++) {
    const dateStr = `${year}-${String(month).padStart(2,'0')}-${String(d).padStart(2,'0')}`;
    const dayEvents = allEvents.filter(e => e.event_date === dateStr);
    const dow = (firstDay + d - 1) % 7;

    const holiday = HOLIDAYS[dateStr];
    const isHoliday = !!holiday;

    const cell = document.createElement('div');
    cell.className = 'cal-cell' +
      (dateStr === todayStr ? ' today' : '') +
      (dow === 0 || isHoliday ? ' sun' : dow === 6 ? ' sat' : '');

    cell.innerHTML = `<span class="cal-day-num">${d}</span>` +
      (holiday ? `<span class="holiday-name">${holiday}</span>` : '');

    dayEvents.slice(0, 3).forEach(ev => {
      const chip = document.createElement('div');
      chip.className = 'event-chip';
      chip.style.background = typeColor(ev.event_type);
      chip.textContent = ev.title;
      cell.appendChild(chip);
    });
    if (dayEvents.length > 3) {
      const more = document.createElement('div');
      more.className = 'event-more';
      more.textContent = `+${dayEvents.length - 3}`;
      cell.appendChild(more);
    }

    cell.addEventListener('click', () => openDayModal(dateStr, dayEvents));
    grid.appendChild(cell);
  }
}

// ── 날짜 상세 모달 ────────────────────────────────────
function openDayModal(dateStr, events) {
  const [y, m, d] = dateStr.split('-');
  const dow = ['일','월','화','수','목','금','토'][new Date(dateStr).getDay()];
  document.getElementById('day-modal-title').textContent =
    `${Number(m)}월 ${Number(d)}일 (${dow})`;

  renderDayEvents(dateStr, events);

  document.getElementById('day-add-btn').onclick = () => requireAdmin(() => openEventForm(dateStr));
  document.getElementById('day-modal-overlay').style.display = 'flex';
}

function renderDayEvents(dateStr, events) {
  const list = document.getElementById('day-event-list');
  if (events.length === 0) {
    list.innerHTML = '<div class="day-empty">일정 없음</div>';
    return;
  }
  list.innerHTML = events.map(ev => `
    <div class="day-event-item">
      <span class="day-event-dot" style="background:${typeColor(ev.event_type)}"></span>
      <div class="day-event-body">
        <div class="day-event-title">${ev.title}</div>
        ${ev.note ? `<div class="day-event-note">${ev.note}</div>` : ''}
        <div class="day-event-type">${ev.event_type}</div>
      </div>
      <div class="day-event-actions">
        <button class="btn-icon" onclick="requireAdmin(()=>openEventForm('${dateStr}','${ev.id}'))">✏️</button>
        <button class="btn-icon" onclick="requireAdmin(()=>deleteEvent('${ev.id}','${dateStr}'))">🗑️</button>
      </div>
    </div>
  `).join('');
}

function closeDayModal() {
  document.getElementById('day-modal-overlay').style.display = 'none';
}

// ── 이벤트 폼 모달 ────────────────────────────────────
function openEventForm(dateStr, editId = null) {
  const existing = editId ? allEvents.find(e => e.id === editId) : null;

  document.getElementById('form-modal-title').textContent = existing ? '일정 수정' : '일정 추가';
  document.getElementById('form-date').value = dateStr;
  document.getElementById('form-title').value = existing ? existing.title : '';
  document.getElementById('form-note').value  = existing ? (existing.note || '') : '';

  const typeSelect = document.getElementById('form-type');
  typeSelect.innerHTML = EVENT_TYPES.map(t =>
    `<option value="${t.key}" ${existing && existing.event_type === t.key ? 'selected' : ''}>${t.key}</option>`
  ).join('');

  document.getElementById('form-save-btn').onclick = () => saveEvent(dateStr, editId);
  document.getElementById('form-modal-overlay').style.display = 'flex';
}

function closeFormModal() {
  document.getElementById('form-modal-overlay').style.display = 'none';
}

async function saveEvent(dateStr, editId) {
  const title = document.getElementById('form-title').value.trim();
  const type  = document.getElementById('form-type').value;
  const note  = document.getElementById('form-note').value.trim();

  if (!title) { alert('제목을 입력해주세요'); return; }

  const payload = { title, event_type: type, event_date: dateStr, note: note || null };

  let error;
  if (editId) {
    ({ error } = await sb.from('calendar_events').update(payload).eq('id', editId));
  } else {
    ({ error } = await sb.from('calendar_events').insert(payload));
  }

  if (error) { alert('저장 실패: ' + error.message); return; }

  closeFormModal();
  await renderCalendar(currentYear, currentMonth);
  // 날짜 모달 새로고침
  const updated = allEvents.filter(e => e.event_date === dateStr);
  renderDayEvents(dateStr, updated);
}

async function deleteEvent(id, dateStr) {
  if (!confirm('삭제할까요?')) return;
  const { error } = await sb.from('calendar_events').delete().eq('id', id);
  if (error) { alert('삭제 실패: ' + error.message); return; }
  await renderCalendar(currentYear, currentMonth);
  const updated = allEvents.filter(e => e.event_date === dateStr);
  renderDayEvents(dateStr, updated);
}

// ── 월 이동 ──────────────────────────────────────────
function prevMonth() {
  let y = currentYear, m = currentMonth - 1;
  if (m < 1) { m = 12; y--; }
  renderCalendar(y, m);
}

function nextMonth() {
  let y = currentYear, m = currentMonth + 1;
  if (m > 12) { m = 1; y++; }
  renderCalendar(y, m);
}

function toDateStr(d) {
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

// init은 index.html의 인라인 스크립트에서 실행
