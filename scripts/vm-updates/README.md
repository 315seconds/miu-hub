# VM 크론 스크립트 업데이트

Oracle VM `~/work_automation/scripts/process_inventory.py` 교체용.

## 변경 요약 (2026-09-21)

새 신규입고 앱의 위치별 자동 바코드(A/U) 및 행거 출처(source) 기록을 지원.

### 코드 변경 요약
1. **`COL_SOURCE = "P"`** 상수 추가 (엑셀 P열 = 출처)
2. **행거 로드 시 `source` 필드 함께 조회**하여 `ordered_items`에 전달
3. **`start_barcode_num` 없어도 스킵 안 함** — 새 세션은 프론트에서 이미 바코드 부여됨
4. **바코드 부여 로직**: `existing_barcode`가 있으면 그대로 사용, 없으면 레거시(prefix+start_num) fallback
5. **`write_inventory_rows`**: 각 행에 P열에 `item['source']` 기록

### 호환성
- **새 세션** (location='공동물류' 또는 '온라인', 바코드 사전 부여됨): P열 기록 + 바코드 유지
- **레거시 세션** (barcode_prefix='C'/'WWA' 등, start_barcode_num 사람이 입력): 기존 방식 그대로 동작

## 배포 순서 (앱 D-day 당일)

```bash
# 1. 백업
ssh -i ~/.oci/oci_instance_key ubuntu@168.107.59.92 \
  "cp ~/work_automation/scripts/process_inventory.py ~/work_automation/scripts/process_inventory.py.bak_$(date +%Y%m%d)"

# 2. 새 파일 업로드
scp -i ~/.oci/oci_instance_key scripts/vm-updates/process_inventory.py \
  ubuntu@168.107.59.92:~/work_automation/scripts/process_inventory.py

# 3. 문법 확인
ssh -i ~/.oci/oci_instance_key ubuntu@168.107.59.92 \
  "cd ~/work_automation && source .venv/bin/activate && python3 -c 'import scripts.process_inventory; print(\"OK\")'"

# 4. 크론 로그 관찰 (2분 이내에 다음 실행 시점 확인)
ssh -i ~/.oci/oci_instance_key ubuntu@168.107.59.92 \
  "tail -f ~/work_automation/logs/inventory_process.log"
```

## 롤백

```bash
ssh -i ~/.oci/oci_instance_key ubuntu@168.107.59.92 \
  "cp ~/work_automation/scripts/process_inventory.py.bak_YYYYMMDD ~/work_automation/scripts/process_inventory.py"
```

## Excel 시트 사전 준비 (사장님이 이미 하심)

- 공동판매 엑셀 `입고` 시트의 P열 헤더에 **`출처`** 입력되어 있어야 함
