// 공통 Supabase 클라이언트. 각 서브앱의 supabase-client.js 대체용.
// 사용법: <script src="/shared/config.js"></script> 다음에 이 파일 로드.
// 그러면 전역 `sb`가 만들어짐.

(function () {
  if (!window.MIU_CONFIG) {
    console.error("[miu] MIU_CONFIG 없음. shared/config.js를 먼저 로드하세요.");
    return;
  }
  if (!window.supabase) {
    console.error("[miu] supabase-js 미로드. CDN 스크립트를 먼저 포함하세요.");
    return;
  }
  // storageKey를 지정하지 않아 Supabase 기본값(sb-<ref>-auth-token) 사용.
  // 모든 서브앱이 자체 sb 클라이언트를 만들어도 같은 기본 키를 참조하므로 세션 자동 공유됨.
  window.sb = window.supabase.createClient(
    window.MIU_CONFIG.SUPABASE_URL,
    window.MIU_CONFIG.SUPABASE_ANON_KEY,
    {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storage: window.localStorage,
      },
    }
  );
})();
