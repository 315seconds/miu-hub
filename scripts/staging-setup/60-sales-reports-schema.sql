-- ============================================================================
-- sales_reports 스키마 (Phase 2)
-- popup_report 이관을 위한 리포트 저장소
-- ============================================================================

BEGIN;

-- ─── 1. sales_reports (리포트 메타 + 집계 결과) ────────────────────────────
CREATE TABLE IF NOT EXISTS public.sales_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 기본 메타
  store        TEXT NOT NULL,                          -- 지점명 (예: 성수, 강남팝업)
  report_type  TEXT NOT NULL CHECK (report_type IN ('main', 'popup')),
                                                       -- main = 성수본점 월별, popup = 팝업 매장
  start_date   DATE NOT NULL,
  end_date     DATE NOT NULL,
  location     TEXT,                                   -- 팝업의 경우 주소 or 장소명

  -- 라벨 (자동 생성 or 수동)
  label        TEXT,                                   -- 예: "2026-08" (main) or "강남 팝업" (popup)

  -- KPI 집계
  total_sales      BIGINT  NOT NULL DEFAULT 0,
  total_cnt        INTEGER NOT NULL DEFAULT 0,
  daily_avg_sales  BIGINT,

  dom_sales        BIGINT  NOT NULL DEFAULT 0,         -- 국내 매출
  dom_cnt          INTEGER NOT NULL DEFAULT 0,
  dom_share        NUMERIC(5,4),                       -- 0.0000 ~ 1.0000

  for_sales        BIGINT  NOT NULL DEFAULT 0,         -- 해외 매출
  for_cnt          INTEGER NOT NULL DEFAULT 0,
  foreign_share    NUMERIC(5,4),

  peak_hour        SMALLINT,                            -- 0~23
  peak_sales       BIGINT,
  top_category     TEXT,

  -- 상세 (JSON)
  hourly_data      JSONB,   -- [{hour:0, 총매출, 국내, 해외, 건수}, ..., {hour:23, ...}]
  top_categories   JSONB,   -- {all_gen:[...], all_on:[...], dom_gen:[...], ...}

  -- 설정 스냅샷
  foreign_keywords TEXT[],  -- 이 리포트 생성 시 사용한 해외 키워드 목록

  -- 원본 파일 (Storage 참조)
  raw_receipt_paths TEXT[],  -- 키오스크별 영수증 경로 (복수)
  raw_card_paths    TEXT[],
  raw_ingo_paths    TEXT[],  -- main + prev (팝업은 2개)

  -- 감사
  created_by  UUID REFERENCES auth.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- 유니크 (같은 지점·타입·기간 리포트 중복 방지 완화 — 재생성 허용)
  UNIQUE (store, report_type, start_date, end_date)
);

CREATE INDEX IF NOT EXISTS idx_sales_reports_type_date
  ON public.sales_reports (report_type, end_date DESC);

CREATE INDEX IF NOT EXISTS idx_sales_reports_store
  ON public.sales_reports (store);

CREATE INDEX IF NOT EXISTS idx_sales_reports_created_by
  ON public.sales_reports (created_by);


-- ─── 2. sales_report_items (아이템별 매출, 시계열 분석용) ──────────────
CREATE TABLE IF NOT EXISTS public.sales_report_items (
  id BIGSERIAL PRIMARY KEY,
  report_id UUID NOT NULL REFERENCES public.sales_reports(id) ON DELETE CASCADE,

  transaction_time TIMESTAMPTZ,
  barcode          TEXT,
  category         TEXT,         -- 소분류 원본 (온 포함)
  category_base    TEXT,         -- 온 제거된 base
  is_online        BOOLEAN,
  is_foreign       BOOLEAN,      -- 해외 결제 여부

  item_amount      NUMERIC(12,2), -- 아이템별 배분된 매출
  approved_amount  BIGINT,        -- 트랜잭션 승인금액
  card_issuer      TEXT,          -- 카드발급사명

  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_report_items_report
  ON public.sales_report_items (report_id);

CREATE INDEX IF NOT EXISTS idx_report_items_barcode
  ON public.sales_report_items (barcode);

CREATE INDEX IF NOT EXISTS idx_report_items_time
  ON public.sales_report_items (transaction_time);

CREATE INDEX IF NOT EXISTS idx_report_items_category
  ON public.sales_report_items (category_base);


-- ─── 3. updated_at 자동 갱신 트리거 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sales_reports_updated_at ON public.sales_reports;
CREATE TRIGGER trg_sales_reports_updated_at
  BEFORE UPDATE ON public.sales_reports
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ─── 4. RLS 정책 (authenticated만 접근) ─────────────────────────────────
ALTER TABLE public.sales_reports        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_report_items   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated_all" ON public.sales_reports;
CREATE POLICY "authenticated_all" ON public.sales_reports
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "authenticated_all" ON public.sales_report_items;
CREATE POLICY "authenticated_all" ON public.sales_report_items
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- anon은 그대로 차단
REVOKE ALL ON public.sales_reports      FROM anon;
REVOKE ALL ON public.sales_report_items FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.sales_reports      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sales_report_items TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.sales_report_items_id_seq  TO authenticated;

COMMIT;

-- ============================================================================
-- Storage 버킷은 SQL로 못 만듦 → Studio에서 수동 생성 필요
-- (다음 스텝에서 안내)
-- ============================================================================
