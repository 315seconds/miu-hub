// 각 서브앱 진입 시 세션 확인 후 없으면 로그인으로 리디렉션.
// 사용법: <script src="/shared/config.js"></script>
//        <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
//        <script src="/shared/supabase-client.js"></script>
//        <script src="/shared/auth-guard.js"></script>
// 이 스크립트 자체는 세션 없으면 즉시 리디렉트하므로 <head>에 넣을 것.

(async function () {
  const cfg = window.MIU_CONFIG || {};
  const publicPaths = cfg.PUBLIC_PATHS || ["/miu-hub/login.html"];
  const path = window.location.pathname;

  // 로그인 페이지 자체는 가드 스킵
  if (publicPaths.some((p) => path.endsWith(p) || path === p)) return;

  if (!window.sb) {
    console.error("[auth-guard] sb 클라이언트 없음");
    return;
  }

  const { data, error } = await window.sb.auth.getSession();
  if (error) {
    console.error("[auth-guard] 세션 확인 실패:", error);
  }

  if (!data.session) {
    // 어디로 돌아올지 기억해두기. searchParams.set이 자동 인코딩하므로 수동 인코딩 X.
    const loginUrl = new URL("/miu-hub/login.html", window.location.origin);
    loginUrl.searchParams.set("returnTo", window.location.href);
    window.location.replace(loginUrl.toString());
    return;
  }

  // 세션 있으면 전역에 사용자 정보 노출
  window.MIU_USER = data.session.user;

  // 프로필(role 포함) 비동기 로드 — window.MIU_PROFILE 로 접근
  window.sb.from('profiles').select('id,email,name,role')
    .eq('id', data.session.user.id).single()
    .then(({ data: profile }) => { window.MIU_PROFILE = profile || null; })
    .catch(() => { window.MIU_PROFILE = null; });

  // 로그아웃 이벤트 리스너 (다른 탭에서 로그아웃 시 이 탭도 반영)
  window.sb.auth.onAuthStateChange((event, session) => {
    if (event === "SIGNED_OUT" || !session) {
      window.location.replace("/miu-hub/login.html");
    }
  });
})();
