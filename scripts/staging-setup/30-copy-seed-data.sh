#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env.staging
mkdir -p out

echo "== 프로덕션 시드 데이터 복사 (테이블당 소량) =="
echo "  주의: PII/PIN 등 민감 데이터도 함께 복사됨. 스테이징도 안전하게 보관!"
echo ""

# 테이블별 복사 정책
# - 마스터성: 전량
# - 트랜잭션성: 최근 100~500행만
declare -A LIMITS=(
  [approvers]="ALL"         # 6건, 하지만 PIN 포함 → 아래 마스킹 옵션 참고
  [handlers]="ALL"          # 14건
  [locations]="ALL"         # 18건
  [brand_master]="ALL"      # 966건
  [calendar_events]="ALL"   # 8건
  [inventory_sessions]="100"
  [inventory_hangers]="200"
  [inventory_items]="500"
  [move_sessions]="100"
  [session_items]="500"
  [sold_items]="500"
  [price_changes]="200"
  [stocktake_sessions]="ALL"
  [stocktake_scans]="500"
  [kiosk_updates]="100"
  [hanger_scans]="200"
  [item_captures]="100"
  [scan_hangers]="50"
)

DUMP_ROW_SQL=""
for table in "${!LIMITS[@]}"; do
  limit="${LIMITS[$table]}"
  if [ "$limit" = "ALL" ]; then
    DUMP_ROW_SQL+="\\COPY (SELECT * FROM public.$table) TO 'out/data_${table}.csv' CSV HEADER;\n"
  else
    DUMP_ROW_SQL+="\\COPY (SELECT * FROM public.$table ORDER BY created_at DESC NULLS LAST LIMIT $limit) TO 'out/data_${table}.csv' CSV HEADER;\n"
  fi
done

echo "-- 프로덕션에서 CSV export --"
echo -e "$DUMP_ROW_SQL" | PGPASSWORD="$PROD_DB_PASSWORD" psql \
  -h "$PROD_DB_HOST" -p 5432 -U postgres -d postgres

echo ""
echo "-- approvers PIN 마스킹 (스테이징엔 진짜 PIN 안 남기기) --"
if [ -f out/data_approvers.csv ]; then
  # PIN 컬럼을 '0000'으로 치환
  python3 - <<'PY'
import csv
rows = list(csv.DictReader(open('out/data_approvers.csv')))
for r in rows:
    r['pin'] = '0000'
with open('out/data_approvers.csv','w',newline='') as f:
    w = csv.DictWriter(f, fieldnames=rows[0].keys())
    w.writeheader()
    w.writerows(rows)
print(f"  approvers {len(rows)}건 PIN 마스킹 완료")
PY
fi

echo ""
echo "-- 스테이징에 CSV import --"
IMPORT_SQL=""
# TRUNCATE 순서: FK 역참조 순
IMPORT_SQL+="TRUNCATE public.item_captures, public.hanger_scans, public.scan_hangers, public.stocktake_scans, public.stocktake_sessions, public.session_items, public.move_sessions, public.kiosk_updates, public.price_changes, public.sold_items, public.inventory_items, public.inventory_hangers, public.inventory_sessions, public.calendar_events, public.brand_master, public.locations, public.handlers, public.approvers CASCADE;\n"
for table in "${!LIMITS[@]}"; do
  IMPORT_SQL+="\\COPY public.$table FROM 'out/data_${table}.csv' CSV HEADER;\n"
done

echo -e "$IMPORT_SQL" | PGPASSWORD="$STAGING_DB_PASSWORD" psql \
  -h "$STAGING_DB_HOST" -p 5432 -U postgres -d postgres

echo ""
echo "== 스테이징 최종 카운트 =="
for table in "${!LIMITS[@]}"; do
  cnt=$(PGPASSWORD="$STAGING_DB_PASSWORD" psql \
    -h "$STAGING_DB_HOST" -p 5432 -U postgres -d postgres -t \
    -c "SELECT count(*) FROM public.$table;" 2>/dev/null | xargs)
  printf "  %-25s %s\n" "$table" "$cnt"
done

echo ""
echo "✅ 시드 완료. 스테이징 스키마 + 소량 데이터 준비됨."
