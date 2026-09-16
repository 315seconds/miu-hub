#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source .env.staging

echo "== 스테이징 RLS 실측 (anon 키로 시도) =="
echo "기대: 모든 SELECT/INSERT/UPDATE/DELETE가 401 또는 빈 결과"
echo ""

# anon 키 없으면 종료
if [ -z "${STAGING_ANON_KEY:-}" ]; then
  echo "STAGING_ANON_KEY가 .env.staging에 없음"
  exit 1
fi

TABLES=(approvers brand_master calendar_events handlers hanger_scans inventory_hangers inventory_items inventory_sessions item_captures kiosk_updates locations move_sessions price_changes scan_hangers session_items sold_items stocktake_scans stocktake_sessions)

echo "테이블                     SELECT  INSERT  UPDATE  DELETE"
echo "-------------------------  ------  ------  ------  ------"
for t in "${TABLES[@]}"; do
  # SELECT — 실 데이터 반환 여부
  sel_body=$(curl -s "$STAGING_URL/rest/v1/$t?select=id&limit=1" \
    -H "apikey: $STAGING_ANON_KEY" -H "Authorization: Bearer $STAGING_ANON_KEY")
  sel_code=$(curl -s -o /dev/null -w "%{http_code}" "$STAGING_URL/rest/v1/$t?select=id&limit=1" \
    -H "apikey: $STAGING_ANON_KEY" -H "Authorization: Bearer $STAGING_ANON_KEY")
  if [ "$sel_code" = "401" ] || [ "$sel_code" = "403" ]; then
    sel="BLOCK"
  elif echo "$sel_body" | grep -q '^\[\]'; then
    sel="EMPTY"
  elif echo "$sel_body" | grep -q '^\['; then
    sel="LEAK!"
  else
    sel="?$sel_code"
  fi

  # INSERT
  ins=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$STAGING_URL/rest/v1/$t" \
    -H "apikey: $STAGING_ANON_KEY" -H "Authorization: Bearer $STAGING_ANON_KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d '{}')
  [ "$ins" = "401" ] || [ "$ins" = "403" ] && ins_r="BLOCK" || ins_r="$ins"

  # UPDATE
  upd=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$STAGING_URL/rest/v1/$t?id=eq.00000000-0000-0000-0000-000000000000" \
    -H "apikey: $STAGING_ANON_KEY" -H "Authorization: Bearer $STAGING_ANON_KEY" \
    -H "Content-Type: application/json" -H "Prefer: return=minimal" -d '{}')
  [ "$upd" = "401" ] || [ "$upd" = "403" ] && upd_r="BLOCK" || upd_r="$upd"

  # DELETE
  del=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$STAGING_URL/rest/v1/$t?id=eq.00000000-0000-0000-0000-000000000000" \
    -H "apikey: $STAGING_ANON_KEY" -H "Authorization: Bearer $STAGING_ANON_KEY")
  [ "$del" = "401" ] || [ "$del" = "403" ] && del_r="BLOCK" || del_r="$del"

  printf "%-25s  %-6s  %-6s  %-6s  %-6s\n" "$t" "$sel" "$ins_r" "$upd_r" "$del_r"
done

echo ""
echo "판정:"
echo "  BLOCK = 401/403 (권한 자체 차단)"
echo "  EMPTY = 200 [] (RLS로 0행 필터링, 실질적으로 안전)"
echo "  LEAK! = 200 [{...}] (⚠️  데이터 노출됨! 정책 확인 필요)"
echo "  기타 숫자 = HTTP status (400=제약위반, 조사 필요)"
