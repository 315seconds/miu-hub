// shared.js — bottom nav + common helpers

const BOTTOM_NAV_TABS = [
  { id: 'hub',      href: '../',               label: '허브',    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>' },
  { id: 'sessions', href: 'session-list.html', label: '신규입고', svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/></svg>' },
  { id: 'approve',  href: 'approve.html',      label: '승인',    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>' },
  { id: 'items',    href: 'items.html',         label: '조회',    svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>' },
  { id: 'more',     href: 'more.html',          label: '더보기',  svg: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/></svg>' },
];

// PAGE_TAB maps filenames to tab IDs
const PAGE_TAB = {
  'index.html': 'home',
  'session-list.html': 'sessions',
  'session.html': 'sessions',
  'hanger.html': 'sessions',
  'bulk-photo.html': 'sessions',
  'approve.html': 'approve',
  'approve-session.html': 'approve',
  'items.html': 'items',
  'more.html': 'more',
  'logs.html': 'more',
  'reprint.html': 'more',
};

function initBottomNav() {
  const filename = location.pathname.split('/').pop() || 'index.html';
  const activeId = PAGE_TAB[filename] || 'home';

  const nav = document.createElement('nav');
  nav.className = 'bottom-nav';
  nav.innerHTML = `<div class="bottom-nav-inner">${
    BOTTOM_NAV_TABS.map(tab => `
      <a href="${tab.href}" class="bottom-nav-btn${tab.id === activeId ? ' active' : ''}">
        ${tab.svg}
        ${tab.label}
      </a>
    `).join('')
  }</div>`;
  document.body.appendChild(nav);
}

// 오늘 날짜 (YYYY.MM.DD 요일)
function getTodayLabel() {
  const days = ['일', '월', '화', '수', '목', '금', '토'];
  const d = new Date();
  return `${d.getFullYear()}년 ${d.getMonth()+1}월 ${d.getDate()}일 (${days[d.getDay()]})`;
}

document.addEventListener('DOMContentLoaded', initBottomNav);

function appConfirm(msg) {
  return new Promise(resolve => {
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box';
    overlay.innerHTML = `
      <div style="background:#1e293b;border-radius:14px;padding:24px 20px;max-width:320px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.5)">
        <div style="color:#f1f5f9;font-size:15px;line-height:1.6;white-space:pre-line;margin-bottom:20px">${escapeHtml(msg)}</div>
        <div style="display:flex;gap:8px">
          <button id="_modal-cancel" style="flex:1;padding:11px;background:#334155;border:none;border-radius:8px;color:#94a3b8;font-size:14px;cursor:pointer">취소</button>
          <button id="_modal-ok" style="flex:1;padding:11px;background:#3b82f6;border:none;border-radius:8px;color:#fff;font-size:14px;font-weight:600;cursor:pointer">확인</button>
        </div>
      </div>`;
    document.body.appendChild(overlay);
    const close = r => { overlay.remove(); resolve(r); };
    overlay.querySelector('#_modal-ok').addEventListener('click', () => close(true));
    overlay.querySelector('#_modal-cancel').addEventListener('click', () => close(false));
    overlay.addEventListener('click', e => { if (e.target === overlay) close(false); });
  });
}

function appAlert(msg) {
  return new Promise(resolve => {
    const overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box';
    overlay.innerHTML = `
      <div style="background:#1e293b;border-radius:14px;padding:24px 20px;max-width:320px;width:100%;box-shadow:0 8px 32px rgba(0,0,0,.5)">
        <div style="color:#f1f5f9;font-size:15px;line-height:1.6;white-space:pre-line;margin-bottom:20px">${escapeHtml(msg)}</div>
        <button id="_modal-ok" style="width:100%;padding:11px;background:#3b82f6;border:none;border-radius:8px;color:#fff;font-size:14px;font-weight:600;cursor:pointer">확인</button>
      </div>`;
    document.body.appendChild(overlay);
    const close = () => { overlay.remove(); resolve(); };
    overlay.querySelector('#_modal-ok').addEventListener('click', close);
    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
  });
}
