-- ============================================================================
-- 옵션 Y: 프로덕션 OpenAPI 스키마 기반으로 스테이징에 18 테이블 재구성
-- ============================================================================
-- 대상: rakfyvxpysmfuzkdoevc (스테이징 전용)
-- 목적: 로그인/RLS 테스트용. 실운영 스키마와 컬럼/타입/PK/기본값 동일.
--       인덱스/RPC/트리거는 미포함 (auth 테스트에 불필요).
-- FK: 코드에서 실제 사용 확인된 것만 반영. 나머지는 논리적 관계만 유지.
-- ============================================================================

-- 확장 (Supabase 기본이지만 명시)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ========== 1. 마스터/독립 테이블 (FK 없음) ==========

CREATE TABLE IF NOT EXISTS public.approvers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  pin TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.brand_master (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.calendar_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  event_date DATE NOT NULL,
  event_type TEXT NOT NULL,
  note TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.handlers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.kiosk_updates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  barcode TEXT NOT NULL,
  new_price INTEGER NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  processed BOOLEAN DEFAULT FALSE,
  processed_at TIMESTAMPTZ,
  excel_failed BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS public.price_changes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  barcode TEXT NOT NULL,
  old_price INTEGER,
  new_price INTEGER NOT NULL,
  changed_by TEXT,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note TEXT,
  excel_updated BOOLEAN DEFAULT FALSE,
  excel_updated_at TIMESTAMPTZ,
  excel_failed BOOLEAN DEFAULT FALSE,
  hanger_number INTEGER,
  printed_at TIMESTAMPTZ,
  store TEXT
);

CREATE TABLE IF NOT EXISTS public.sold_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  barcode TEXT NOT NULL,
  sold_date DATE NOT NULL,
  store TEXT,
  product_name TEXT,
  price INTEGER,
  created_at TIMESTAMPTZ DEFAULT now(),
  quantity INTEGER NOT NULL DEFAULT 1,
  refund_date DATE,
  refund_type TEXT
);

-- ========== 2. 세션 테이블 (다른 테이블이 참조) ==========

CREATE TABLE IF NOT EXISTS public.inventory_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_date DATE NOT NULL DEFAULT CURRENT_DATE,
  barcode_prefix TEXT NOT NULL DEFAULT 'C',
  start_barcode_num TEXT,
  total_items INTEGER,
  online_toggle BOOLEAN NOT NULL DEFAULT FALSE,
  location TEXT NOT NULL DEFAULT '공동물류',
  status TEXT NOT NULL DEFAULT 'pending',
  created_by TEXT,
  approved_by TEXT,
  approved_at TIMESTAMPTZ,
  excel_updated BOOLEAN NOT NULL DEFAULT FALSE,
  excel_updated_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.move_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_date DATE NOT NULL,
  from_location TEXT NOT NULL,
  to_location TEXT NOT NULL,
  status TEXT DEFAULT 'pending',
  created_by TEXT NOT NULL,
  approved_by TEXT,
  approved_at TIMESTAMPTZ,
  is_correction BOOLEAN DEFAULT FALSE,
  correction_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  excel_updated BOOLEAN DEFAULT FALSE,
  excel_updated_at TIMESTAMPTZ,
  excel_updated_count INTEGER
);

CREATE TABLE IF NOT EXISTS public.stocktake_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'in_progress',
  report_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.scan_hangers (
  id BIGSERIAL PRIMARY KEY,
  device_id UUID NOT NULL,
  hanger_number INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  completed_at_kst TIMESTAMP
);

-- ========== 3. 세션에 종속된 테이블 ==========

CREATE TABLE IF NOT EXISTS public.inventory_hangers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.inventory_sessions(id) ON DELETE CASCADE,
  hanger_number TEXT NOT NULL,
  category TEXT NOT NULL,
  is_online BOOLEAN NOT NULL DEFAULT FALSE,
  submitted_by TEXT,
  submitted_at TIMESTAMPTZ,
  item_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  printed_at TIMESTAMPTZ,
  kiosk_exported_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.inventory_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES public.inventory_sessions(id) ON DELETE SET NULL,
  hanger_id UUID REFERENCES public.inventory_hangers(id) ON DELETE SET NULL,
  order_index INTEGER NOT NULL DEFAULT 0,
  price INTEGER NOT NULL,
  brand TEXT,
  barcode TEXT,
  product_name TEXT,
  photo_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'in_stock',
  location TEXT,
  category TEXT,
  color TEXT,
  pattern TEXT
);

CREATE TABLE IF NOT EXISTS public.session_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES public.move_sessions(id) ON DELETE CASCADE,
  barcode TEXT NOT NULL,
  product_name TEXT,
  category TEXT,
  price TEXT,
  current_location TEXT,
  scanned_by TEXT NOT NULL,
  scanned_at TIMESTAMPTZ DEFAULT now(),
  is_error BOOLEAN DEFAULT FALSE,
  error_msg TEXT,
  is_submitted BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS public.stocktake_scans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID REFERENCES public.stocktake_sessions(id) ON DELETE CASCADE,
  barcode TEXT NOT NULL,
  scanned_location TEXT NOT NULL,
  scanner_name TEXT NOT NULL,
  scanned_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.hanger_scans (
  id BIGSERIAL PRIMARY KEY,
  hanger_id BIGINT NOT NULL REFERENCES public.scan_hangers(id) ON DELETE CASCADE,
  device_id UUID NOT NULL,
  barcode TEXT NOT NULL,
  brand_needed BOOLEAN NOT NULL DEFAULT FALSE,
  photo_needed BOOLEAN NOT NULL DEFAULT FALSE,
  brand_captured BOOLEAN NOT NULL DEFAULT FALSE,
  photo_captured BOOLEAN NOT NULL DEFAULT FALSE,
  scanned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  scanned_at_kst TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.item_captures (
  id BIGSERIAL PRIMARY KEY,
  barcode TEXT NOT NULL,
  brand TEXT,
  storage_path TEXT,
  device_id UUID NOT NULL,
  hanger_scan_id BIGINT REFERENCES public.hanger_scans(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at_kst TIMESTAMP
);

-- ========== 4. 최소 시드 데이터 (로그인/RLS 테스트용) ==========
-- 실 데이터 아님. 폰에서 화면 그려질 정도만.

INSERT INTO public.locations (name, is_active) VALUES
  ('공동물류', TRUE), ('성수255', TRUE), ('용산', TRUE), ('회현', TRUE), ('영등포', TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO public.handlers (name, is_active) VALUES
  ('테스트직원1', TRUE), ('테스트직원2', TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO public.approvers (name, pin) VALUES
  ('테스트승인자', '0000')
ON CONFLICT DO NOTHING;

INSERT INTO public.brand_master (id, name) VALUES
  (1, '나이키'), (2, '아디다스'), (3, 'Vintage')
ON CONFLICT DO NOTHING;

INSERT INTO public.calendar_events (title, event_date, event_type, note) VALUES
  ('테스트 팝업', CURRENT_DATE + 7, 'popup', 'staging seed')
ON CONFLICT DO NOTHING;

-- 확인용
DO $$
DECLARE
  t text; c bigint;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', t) INTO c;
    RAISE NOTICE '  %: % rows', t, c;
  END LOOP;
END $$;
