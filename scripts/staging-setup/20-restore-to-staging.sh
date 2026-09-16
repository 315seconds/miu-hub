#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env.staging
DUMPFILE="out/prod-schema.sql"

if [ ! -f "$DUMPFILE" ]; then
  echo "✗ $DUMPFILE 없음. 먼저 ./10-dump-prod-schema.sh 실행"
  exit 1
fi

echo "== 스테이징에 스키마 restore =="
echo "  대상: $STAGING_DB_HOST"
echo "  입력: $DUMPFILE"
echo ""

# 안전장치: 스테이징 DB에 public 테이블이 이미 있으면 확인 요청
existing=$(PGPASSWORD="$STAGING_DB_PASSWORD" psql \
  -h "$STAGING_DB_HOST" -p 5432 -U postgres -d postgres -t \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | xargs)

if [ "${existing:-0}" -gt "0" ]; then
  echo "⚠️  스테이징 public 스키마에 이미 $existing 개 테이블이 있습니다."
  read -p "  덮어쓰기 계속? (yes 입력): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "취소됨."
    exit 1
  fi
fi

echo ""
echo "restore 실행 중..."
PGPASSWORD="$STAGING_DB_PASSWORD" psql \
  -h "$STAGING_DB_HOST" -p 5432 -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -f "$DUMPFILE" 2>&1 | tail -20

echo ""
echo "== 스테이징 검증 =="
PGPASSWORD="$STAGING_DB_PASSWORD" psql \
  -h "$STAGING_DB_HOST" -p 5432 -U postgres -d postgres -t \
  -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name;"

echo ""
echo "✅ Restore 완료. 다음: (선택) ./30-copy-seed-data.sh"
