-- ============================================================================
-- miu-hub RLS 정책 초안 (1단계: 인증만 필요, 역할 분리는 이후 단계)
-- ============================================================================
-- 실행 대상: 스테이징 프로젝트 (프로덕션 절대 금지! 검증 후 별도 반영)
-- 실행 방법: Supabase Studio > SQL Editor에 붙여넣고 실행
--          또는 psql로:
--          PGPASSWORD=$STAGING_DB_PASSWORD psql -h $STAGING_DB_HOST -U postgres \
--            -d postgres -f 40-rls-policies.sql
--
-- 정책 원칙 (1단계):
--   * 익명(anon) 역할: 완전 차단
--   * 인증된 사용자(authenticated): 전부 읽기/쓰기 허용
--   * 감사가 필요한 컬럼(created_by 등)은 아직 free text 유지, 2단계에서 auth.uid()로
--
-- 2단계에서 추가할 것:
--   * profiles(user_id, role) 테이블
--   * viewer/operator/manager/admin 역할별 정책 세분화
--   * approvers/승인 액션은 manager 이상만
--   * Storage 정책
-- ============================================================================

BEGIN;

-- 대상 테이블 목록 (18개)
DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'approvers', 'brand_master', 'calendar_events', 'handlers',
    'hanger_scans', 'inventory_hangers', 'inventory_items', 'inventory_sessions',
    'item_captures', 'kiosk_updates', 'locations',
    'move_sessions', 'price_changes', 'scan_hangers',
    'session_items', 'sold_items', 'stocktake_scans', 'stocktake_sessions'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    -- 1) RLS 활성화 (이미 켜져 있어도 idempotent)
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

    -- 2) 기존 anon 관련 정책 제거 (있으면)
    --    정책 이름은 프로젝트마다 다를 수 있으니 스테이징에서 실제 이름 확인 후 조정
    EXECUTE format('DROP POLICY IF EXISTS "anon_all" ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable read access for all users" ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable insert for all users" ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable update for all users" ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS "Enable delete for all users" ON public.%I', t);

    -- 3) authenticated 전체 CRUD 허용 (1단계 목표)
    EXECUTE format($p$
      CREATE POLICY "authenticated_all" ON public.%I
        FOR ALL
        TO authenticated
        USING (true)
        WITH CHECK (true)
    $p$, t);
  END LOOP;
END $$;

-- 4) anon 역할의 테이블 권한 자체 회수 (RLS 이중 방어)
--    RLS만 걸어도 되지만, 명시적으로 GRANT/REVOKE 정리하면 실수 방지
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- 5) authenticated 역할 권한 부여 (기본은 이미 있지만 명시)
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

-- 6) 향후 생성될 객체에도 기본권한 반영
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;

COMMIT;

-- ============================================================================
-- 검증 쿼리 (실행 후 확인)
-- ============================================================================

-- (A) RLS가 켜져 있는지
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
-- 기대: 모든 rowsecurity = t

-- (B) 각 테이블의 정책 목록
SELECT schemaname, tablename, policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
-- 기대: 모든 테이블에 authenticated_all 하나씩

-- (C) anon 역할의 실제 grant
SELECT table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'anon' AND table_schema = 'public'
ORDER BY table_name;
-- 기대: 결과 없음 (전부 회수됨)

-- ============================================================================
-- 실측 (스테이징에서 anon 키로 shell에서 시도)
-- ============================================================================
-- STAGING_ANON=<staging anon key>
-- curl -s "$STAGING_URL/rest/v1/inventory_items?select=id&limit=1" \
--   -H "apikey: $STAGING_ANON" -H "Authorization: Bearer $STAGING_ANON"
-- → 기대 응답: {"code":"42501","message":"permission denied for table inventory_items"}
--    또는 빈 배열 [] with 200 (RLS로 필터링)
-- ============================================================================
