#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env.staging
mkdir -p out

OUTFILE="out/prod-schema.sql"

echo "== 프로덕션 스키마 덤프 (읽기 전용) =="
echo "  대상: $PROD_DB_HOST"
echo "  출력: $OUTFILE"
echo ""

# --schema-only: 데이터 X, 구조만
# --no-owner --no-privileges: 스테이징에 restore할 때 롤/권한 충돌 방지
# --schema=public: public 스키마만 (auth, storage, extensions는 Supabase가 자동 생성)
# --schema=storage: storage 정책도 필요하면 이 줄 추가
PGPASSWORD="$PROD_DB_PASSWORD" pg_dump \
  -h "$PROD_DB_HOST" -p 5432 -U postgres -d postgres \
  --schema-only \
  --no-owner \
  --no-privileges \
  --schema=public \
  --file="$OUTFILE"

echo "덤프 완료. 파일 크기:"
wc -l "$OUTFILE"
echo ""
echo "== 덤프된 객체 요약 =="
grep -E "^(CREATE TABLE|CREATE INDEX|CREATE FUNCTION|CREATE POLICY|ALTER TABLE.*ENABLE ROW)" "$OUTFILE" | sort | uniq -c | sort -rn | head -20

echo ""
echo "✅ 프로덕션 덤프 완료. 다음: ./20-restore-to-staging.sh"
echo ""
echo "⚠️  참고: RLS 정책도 덤프됨. 스테이징에서 정책을 일부러 부수는 실험을 하려면"
echo "   restore 후 별도로 DROP POLICY 실행하세요."
