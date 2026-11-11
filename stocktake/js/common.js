// 재고조사 공용 도우미. 로드 순서: config.js → supabase-js → supabase-client.js → auth-guard.js → 이 파일
(function () {
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmt = (n) => Number(n || 0).toLocaleString('ko-KR');

  // 결과 종류. tone = 칩 색(.miu-chip.<tone>), order = 목록 정렬/탭 순서
  const KIND = {
    missing:          { label: '미스캔',        tone: 'danger',  order: 1, desc: '장부에는 있는데 조사에서 나오지 않은 물건이에요. 조사를 닫으면 "미확인"으로 표시되고 재고에는 그대로 남아요. 현장에서 찾았으면 "찾음", 택분실로 새로 입고한 물건과 짝이 확인되면 "택분실 짝 확인 후 폐기", 나머지는 "미확인 위치로 이동"해 두세요. 다음 조사에서 어디서든 나오면 자동으로 발견 목록에 떠요. 조사 당일에 팔린 물건은 다음 날 새벽 판매 집계 뒤에 조사를 닫으면 여기가 아니라 "조사 중 변동"으로 빠져요.' },
    sold_scanned:     { label: '판매됨인데 스캔', tone: 'danger',  order: 2, desc: '장부상 판매 처리된 물건이 매장에서 스캔됐어요. 반품·택갈이·판매 오입력일 수 있어 판매 정정이 필요한지 확인해 주세요.' },
    disposed_scanned: { label: '폐기인데 스캔',  tone: 'danger',  order: 3, desc: '장부상 폐기 처리된 물건이 스캔됐어요. 폐기 처리가 잘못됐는지 확인해 주세요.' },
    unknown:          { label: '장부에 없음',    tone: 'danger',  order: 4, desc: '장부에서 찾을 수 없는 바코드예요. 바코드를 잘못 읽었거나 입고 누락, 택분실 신규 입고일 수 있어요.' },
    location_diff:    { label: '위치 다름',     tone: 'warn',    order: 5, desc: '스캔한 위치와 장부 위치가 달라요. 확인한 뒤 위치 정정을 예약하면 22:00 자동 승인 뒤 장부(DB·엑셀)가 바뀌어요. 한 번에 여러 건을 선택해서 처리할 수 있어요.' },
    missing_found:    { label: '미확인 물건 발견', tone: 'success', order: 6, desc: '이전 조사에서 안 나와 "미확인"으로 표시돼 있던 물건이 이번에 스캔됐어요. 발견 처리하면 미확인 표시가 풀리고, 장부 위치와 다르면 위치 정정이 예약돼요.' },
    duplicate:        { label: '중복 스캔',     tone: 'muted',   order: 7, desc: '같은 바코드가 두 번 이상 스캔됐어요. 같은 바코드로 여러 벌 관리되는 물건이면 문제 없음으로 처리해요.' },
    changed:          { label: '조사 중 변동',   tone: 'muted',   order: 8, desc: '조사하는 동안 판매돼서 장부가 바뀐 물건이에요. 판매는 다음 날 새벽에 장부에 반영되므로, 조사 뒤 판매가 반영된 상태에서 닫으면 미스캔이 아니라 여기로 와요. 대개 조치가 필요 없어요.' },
  };
  const RES = { open: '미처리', found: '찾음', ignored: '문제 없음', moved: '위치 정정 예약', disposed: '폐기 예약' };

  // RPC 호출. 실패하면 사람이 읽을 메시지를 담은 Error(.hint, .code 포함)를 던진다.
  async function rpc(name, args) {
    const { data, error } = await window.sb.rpc(name, args || {});
    if (error) {
      const e = new Error(error.message || '요청에 실패했어요.');
      e.hint = error.hint || '';
      e.code = error.code || '';
      e.network = !error.code && /fetch|network|failed/i.test(error.message || '');
      throw e;
    }
    return data;
  }

  // 로그인 사용자와 역할(프로필 로딩을 기다린다)
  async function whoami() {
    for (let i = 0; i < 50 && window.MIU_PROFILE === undefined; i++) await new Promise((r) => setTimeout(r, 100));
    const p = window.MIU_PROFILE;
    return { id: window.MIU_USER?.id || null, name: p?.name || '', isAdmin: p?.role === 'admin' };
  }

  // 진행 중인 세션(없으면 null). 진행 중 세션은 DB가 하나만 허용한다.
  async function activeSession() {
    const { data, error } = await window.sb.from('stocktake_sessions')
      .select('id,session_date,note,started_by,started_at').eq('status', 'in_progress').maybeSingle();
    if (error) throw new Error(error.message);
    return data;
  }

  const md = (iso) => { const [, m, d] = String(iso).slice(0, 10).split('-'); return `${+m}월 ${+d}일`; };
  const kstTime = (iso) => new Date(iso).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Asia/Seoul' });
  const kstDateTime = (iso) => new Date(iso).toLocaleString('ko-KR', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Asia/Seoul' });

  // CSV 셀: 따옴표 이스케이프 + 엑셀 수식 주입 방지
  const csvCell = (v) => {
    let s = String(v ?? '');
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
    return '"' + s.replace(/"/g, '""') + '"';
  };

  window.ST = { esc, fmt, KIND, RES, rpc, whoami, activeSession, md, kstTime, kstDateTime, csvCell };
})();
