// 통합 관리 스크립트 — 매장 · 직원 · 거래처

const $ = id => document.getElementById(id);

function toast(msg, type='ok') {
  const el = $('toast');
  el.textContent = msg;
  el.className = 'toast show' + (type==='error' ? ' error' : '');
  clearTimeout(window.__toastTimer);
  window.__toastTimer = setTimeout(() => el.classList.remove('show'), 2400);
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

// ────────────────────────────────────────────────────────────
// 접근 권한 게이트
// ────────────────────────────────────────────────────────────
async function checkAdmin() {
  // auth-guard가 세션 확인 후 window.MIU_PROFILE 세팅 (비동기)
  // 최대 3초 대기
  for (let i = 0; i < 30; i++) {
    if (window.MIU_PROFILE !== undefined) break;
    await new Promise(r => setTimeout(r, 100));
  }
  const role = window.MIU_PROFILE?.role;
  if (role !== 'admin') {
    $('gate').style.display = 'block';
    return false;
  }
  $('body').style.display = 'block';
  return true;
}

// ────────────────────────────────────────────────────────────
// 탭 전환
// ────────────────────────────────────────────────────────────
document.querySelectorAll('.admin-tab').forEach(btn => {
  btn.addEventListener('click', () => {
    const tab = btn.dataset.tab;
    document.querySelectorAll('.admin-tab').forEach(b => b.classList.toggle('active', b === btn));
    document.querySelectorAll('.admin-section').forEach(s => s.classList.toggle('active', s.dataset.section === tab));
  });
});

// ────────────────────────────────────────────────────────────
// 매장 관리
// ────────────────────────────────────────────────────────────
async function loadLocations() {
  const { data, error } = await sb.from('locations').select('*').order('is_active', { ascending: false }).order('name');
  if (error) { toast('매장 로드 실패: ' + error.message, 'error'); return; }
  const list = $('loc-list');
  if (!data.length) { list.innerHTML = '<div class="section-hint">등록된 매장이 없어요.</div>'; return; }
  list.innerHTML = data.map(l => `
    <div class="list-item ${l.is_active ? '' : 'inactive'}">
      <div class="name">${esc(l.name)}${l.is_active ? '' : '<div class="name-sub">비활성</div>'}</div>
      <div class="actions">
        <button data-loc-toggle="${l.id}" data-active="${l.is_active}">${l.is_active ? '비활성' : '활성'}</button>
        <button class="danger" data-loc-delete="${l.id}" data-name="${esc(l.name)}">삭제</button>
      </div>
    </div>
  `).join('');
  list.querySelectorAll('[data-loc-toggle]').forEach(b => b.onclick = () => toggleLocation(b.dataset.locToggle, b.dataset.active === 'true'));
  list.querySelectorAll('[data-loc-delete]').forEach(b => b.onclick = () => deleteLocation(b.dataset.locDelete, b.dataset.name));
}
async function addLocation(name) {
  const { error } = await sb.from('locations').insert({ name });
  if (error) { toast('추가 실패: ' + error.message, 'error'); return; }
  toast(`'${name}' 매장 추가됨`);
  loadLocations();
}
async function toggleLocation(id, currActive) {
  const { error } = await sb.from('locations').update({ is_active: !currActive }).eq('id', id);
  if (error) { toast(error.message, 'error'); return; }
  loadLocations();
}
async function deleteLocation(id, name) {
  if (!confirm(`'${name}' 매장을 정말 삭제하시겠어요? 과거 이동 기록은 유지됩니다.`)) return;
  const { error } = await sb.from('locations').delete().eq('id', id);
  if (error) { toast('삭제 실패: ' + error.message, 'error'); return; }
  toast('삭제됨');
  loadLocations();
}
$('loc-form').addEventListener('submit', e => {
  e.preventDefault();
  const name = $('loc-name').value.trim();
  if (!name) return;
  addLocation(name);
  $('loc-name').value = '';
});

// ────────────────────────────────────────────────────────────
// 직원 관리 (profiles 기반)
// ────────────────────────────────────────────────────────────
async function loadStaff() {
  const { data, error } = await sb.from('profiles').select('id, email, name, role, is_handler').order('role', { ascending: false }).order('name');
  if (error) { toast('직원 로드 실패: ' + error.message, 'error'); return; }
  const list = $('staff-list');
  if (!data.length) { list.innerHTML = '<div class="section-hint">등록된 직원이 없어요.</div>'; return; }
  list.innerHTML = data.map(p => `
    <div class="list-item">
      <div class="name">${esc(p.name || '(이름 미설정)')}<div class="name-sub">${esc(p.email)}</div></div>
      <span class="role-badge ${p.role === 'admin' ? 'admin' : ''}">${p.role === 'admin' ? '관리자' : '일반'}</span>
      <div class="actions">
        <button data-edit="${p.id}">편집</button>
        <button class="danger" data-remove="${p.id}" data-name="${esc(p.name || p.email)}">삭제</button>
      </div>
    </div>
  `).join('');
  list.querySelectorAll('[data-edit]').forEach(b => b.onclick = () => editStaff(b.dataset.edit, data.find(x => x.id === b.dataset.edit)));
  list.querySelectorAll('[data-remove]').forEach(b => b.onclick = () => removeStaff(b.dataset.remove, b.dataset.name));
}

async function editStaff(id, cur) {
  const name = prompt('이름', cur.name || '');
  if (name === null) return;
  const role = prompt('역할 (admin / employee)', cur.role);
  if (role === null) return;
  if (!['admin','employee'].includes(role)) { toast('역할은 admin 또는 employee', 'error'); return; }
  const isHandler = confirm('담당자 리스트에 표시할까요?\n(취소=제외)');
  const { error } = await sb.from('profiles').update({ name: name.trim(), role, is_handler: isHandler }).eq('id', id);
  if (error) { toast(error.message, 'error'); return; }
  toast('수정됨');
  loadStaff();
}

async function removeStaff(id, name) {
  alert(`직원 '${name}' 완전 삭제는 Supabase 대시보드에서 진행해주세요.\n(로그인 계정과 함께 제거되어야 해요)\n\n임시로 담당자 리스트에서만 빼려면 '편집' 후 담당자여부를 해제하세요.`);
}

// ────────────────────────────────────────────────────────────
// 거래처 관리
// ────────────────────────────────────────────────────────────
async function loadSources() {
  const { data, error } = await sb.from('sources').select('*').order('is_active', { ascending: false }).order('name');
  if (error) { toast('거래처 로드 실패: ' + error.message, 'error'); return; }
  const list = $('src-list');
  if (!data.length) { list.innerHTML = '<div class="section-hint">등록된 거래처가 없어요.</div>'; return; }
  list.innerHTML = data.map(s => `
    <div class="list-item ${s.is_active ? '' : 'inactive'}">
      <div class="name">${esc(s.name)}${s.is_active ? '' : '<div class="name-sub">비활성</div>'}</div>
      <div class="actions">
        <button data-src-toggle="${s.id}" data-active="${s.is_active}">${s.is_active ? '비활성' : '활성'}</button>
        <button class="danger" data-src-delete="${s.id}" data-name="${esc(s.name)}">삭제</button>
      </div>
    </div>
  `).join('');
  list.querySelectorAll('[data-src-toggle]').forEach(b => b.onclick = () => toggleSource(b.dataset.srcToggle, b.dataset.active === 'true'));
  list.querySelectorAll('[data-src-delete]').forEach(b => b.onclick = () => deleteSource(b.dataset.srcDelete, b.dataset.name));
}
async function addSource(name) {
  const { error } = await sb.from('sources').insert({ name });
  if (error) { toast(error.code === '23505' ? '이미 등록된 거래처예요' : '추가 실패: ' + error.message, 'error'); return; }
  toast(`'${name}' 거래처 추가됨`);
  loadSources();
}
async function toggleSource(id, currActive) {
  const { error } = await sb.from('sources').update({ is_active: !currActive }).eq('id', id);
  if (error) { toast(error.message, 'error'); return; }
  loadSources();
}
async function deleteSource(id, name) {
  if (!confirm(`'${name}' 거래처를 삭제하시겠어요?`)) return;
  const { error } = await sb.from('sources').delete().eq('id', id);
  if (error) { toast('삭제 실패: ' + error.message, 'error'); return; }
  toast('삭제됨');
  loadSources();
}
$('src-form').addEventListener('submit', e => {
  e.preventDefault();
  const name = $('src-name').value.trim();
  if (!name) return;
  addSource(name);
  $('src-name').value = '';
});

// ────────────────────────────────────────────────────────────
// 진입
// ────────────────────────────────────────────────────────────
const sb = window.sb;
(async () => {
  if (!await checkAdmin()) return;
  loadLocations();
  loadStaff();
  loadSources();
})();
