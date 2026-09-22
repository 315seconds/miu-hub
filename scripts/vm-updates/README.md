# Oracle VM 자동화 연계

VM에서 실행되는 Python 코드의 정식 원본은 `315seconds/work_automation`에서 관리합니다.
이 저장소에는 배포용 복사본을 두지 않습니다.

## 신규입고 앱 연계 버전

- 프론트엔드: `miu-hub` 커밋 `b74bfd5`
- VM 자동화 기준점: `work_automation` 커밋 `0480dff`
- 바코드 입력 안전 보완: `work_automation` 커밋 `70d0a3e`
- 정식 파일: `work_automation/scripts/process_inventory.py`
- DB 마이그레이션: `work_automation/inventory_add_hanger_source.sql`

새 신규입고 앱은 위치별 자동 바코드(A/U)와 행거 출처를 저장합니다. VM 자동화는
미리 부여된 바코드를 유지하고, 레거시 세션에는 기존 채번 방식을 사용하며, 출처를
공동판매 엑셀 `입고` 시트 P열에 기록합니다.

VM 자동화 변경과 배포는 반드시 `work_automation`에서 먼저 커밋한 뒤 진행합니다.
