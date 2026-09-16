#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "== 사전 체크 =="

# 1) pg_dump / psql 설치 확인
missing=0
for tool in pg_dump psql; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  ✓ $tool: $(command -v $tool) ($($tool --version | head -1))"
  else
    echo "  ✗ $tool 없음"
    missing=1
  fi
done

if [ "$missing" = "1" ]; then
  echo ""
  echo "설치 방법 (macOS):"
  echo "  brew install libpq"
  echo "  brew link --force libpq"
  exit 1
fi

# 2) .env.staging 확인
if [ ! -f .env.staging ]; then
  echo "  ✗ .env.staging 없음 - README 참고해서 생성"
  exit 1
fi
echo "  ✓ .env.staging 있음"

# 3) 필수 변수 확인
source .env.staging
required=(PROD_DB_HOST PROD_DB_PASSWORD STAGING_DB_HOST STAGING_DB_PASSWORD STAGING_URL STAGING_ANON_KEY)
for var in "${required[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "  ✗ $var 미설정"
    exit 1
  fi
done
echo "  ✓ 필수 환경변수 6개 모두 설정됨"

# 4) 프로덕션 접속 테스트 (읽기만)
echo ""
echo "== 프로덕션 접속 테스트 (SELECT 1) =="
PGPASSWORD="$PROD_DB_PASSWORD" psql \
  -h "$PROD_DB_HOST" -p 5432 -U postgres -d postgres \
  -c "SELECT 1 as prod_ok;" -t 2>&1 | head -3

# 5) 스테이징 접속 테스트
echo ""
echo "== 스테이징 접속 테스트 (SELECT 1) =="
PGPASSWORD="$STAGING_DB_PASSWORD" psql \
  -h "$STAGING_DB_HOST" -p 5432 -U postgres -d postgres \
  -c "SELECT 1 as staging_ok;" -t 2>&1 | head -3

echo ""
echo "✅ 사전 체크 통과. 다음: ./10-dump-prod-schema.sh"
