// shared.js — 공통 유틸리티 (하단 네비는 디자인 통일로 제거됨)

// 이 기기에서 마지막으로 선택한 담당자 이름 — "내 행거" 판별에 사용 (실제 권한 통제 아님, UI 가드용)
const MY_NAME_KEY = "miu-my-name";
function getMyName() { return localStorage.getItem(MY_NAME_KEY) || ""; }
function setMyName(name) { if (name) localStorage.setItem(MY_NAME_KEY, name); }

// 오늘 날짜 (YYYY.MM.DD 요일)
function getTodayLabel() {
  const days = ['일', '월', '화', '수', '목', '금', '토'];
  const d = new Date();
  return `${d.getFullYear()}년 ${d.getMonth()+1}월 ${d.getDate()}일 (${days[d.getDay()]})`;
}

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

function viewPhoto(url) {
  const overlay = document.createElement('div');
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.85);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px;box-sizing:border-box';
  overlay.innerHTML = `<img src="${escapeHtml(url)}" style="max-width:100%;max-height:100%;object-fit:contain;border-radius:8px" alt="사진 원본">`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', () => overlay.remove());
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
