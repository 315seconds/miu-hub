# MIU Hub — 코드만 봐서는 알 수 없는 것들

허브 작업 전에 읽는다. 구조·함수 위치는 코드에서 직접 찾는다(적지 않음). 여기엔 **저장소 밖 상태, 규칙, 함정**만 둔다.
검증일 2026-10-26(운영 DB는 읽기 전용 조회로 확인). 미확인은 `[추정]`.

> 이 저장소는 **공개**다. 서버 주소, 키 위치·값, PIN, 취약점 상세를 여기나 커밋에 쓰지 않는다. 비공개 운영 메모는 `../work_automation/HANDOFF_*.md`.
> 줄기가 바뀌는 작업(새 기능, 권한·DB 구조, 배포·인증 방식, 외부 연동)을 끝내면 이 문서와 맨 아래 이력을 같은 작업에서 갱신한다. 자잘한 수정은 `git log`로 충분.

## 1. 개요와 배포
- 마켓인유(빈티지 의류) 물류·판매용 정적 PWA. 빌드 없음. HTML/JS + Supabase(`miu_ops` 프로젝트: Auth, Postgres RLS/RPC, Storage, Realtime). 한국어. 사용자 약 11명(관리자 5).
- 배포: `main` push → GitHub Pages 자동 빌드(약 1분, `https://315seconds.github.io/miu-hub/`).
- 공유 JS/CSS(`shared/*`, 각 `js/*`)를 바꿨으면 먼저 `python3 scripts/bump-cache-version.py`(모든 HTML의 로컬 js/css `?v=` 갱신, 현재 `202610250918`). HTML만 바꿨으면 불필요. 직원 폰은 새로고침/앱 재실행 필요.
- 로컬: `python3 scripts/dev-server.py [포트]`(127.0.0.1 전용).
- 서버 자동화(엑셀/Dropbox 반영, 자동 승인, 레터 생성)는 **이 저장소 밖**(`../work_automation`, Oracle VM 크론). 5절.

## 2. 폴더 이름 ↔ 기능 (이름만으로 알기 어려운 것)
| 폴더 | 기능 |
|---|---|
| `receiving/` | 신규 입고(세션→행거→물건→제출→승인→라벨) + 통합 물건 조회(`items`) + 바코드 재출력(`reprint`) + 가격수정 이력(`price-change-log`) |
| `move/` | 물류 이동(단일 2700줄 `index.html`) |
| `longterm/` | 장기 재고 가격 변경. 홈의 "가격 수정" 타일은 `longterm/?direct=1` |
| `dashboard/` | 매장 현황판 + 재고조사 결과 + 매장 철수(`#home #closed #stocktake #loc/<이름>` 해시 라우팅) |
| `inventory-check/` | 재고 조사 스캐너(오프라인 견딤) |
| `sold-report/`, `turnover/` | 일별 판매 리포트 / 회전율(`turnover`는 홈 메뉴에 없음, 직접 URL) |
| `report/` | 매출 리포트(키오스크 엑셀 업로드→파싱→분석→`sales_reports`). `migrate.html`, `patch-*.html`은 일회성 |
| `letter/` | 주간 프라이싱 레터(`index`, `all`, `status`=황태훈 전용 열람 현황) |
| `sales-letter/` | 판매 레터(김민지 수신, 황태훈은 열람 현황에서 확인): 평일 아침 지난 영업일 판매된 대상 물건 목록(`sales_letters`) |
| `logistics-request/` | 매장 매니저 최영훈(+황태훈) 전용 물류요청 보조: 기간·매장 선택 → 카테고리별 판매수량+가격대 분포 엑셀. 브라우저에서 `sold_items`×`inventory_items.category` 집계(DB 변경 없음) |
| `category-analysis/` | 최영훈·황태훈 전용 카테고리 판매 분석(시트 "카테고리자동화"의 허브판). 기간·매장 → 판매벌수·판매액·평균가·행거당 판매액·효율지수/신호·재고 소진·가격대·직전 기간 대비, 매장 비교, **행거수 이력 입력**, 엑셀. 집계는 RPC `category_performance` |
| `manual/` | 매장 업무: `index.html`=오늘 체크리스트·특이사항 메모·업무 매뉴얼(검색), `admin.html`=관리자 전용 날짜별 현황(매장×최근 14일 표, 체크한 사람·시각, 메모 확인)·매뉴얼 글·체크 항목 편집. 홈 "매장 업무" 섹션 |
| `item-scanner/` | 브랜드·사진 스캐너 |
| `admin/` | 통합 관리(role=admin): 매장, 직원(이름·등급·담당자), 거래처 |
| `calendar/`, `login.html`, `design-system.html`(미링크 데모) | |

## 3. 공통 계약 (페이지마다 다시 만들지 말 것)
- 로드 순서: tokens.css → layout.css → supabase-js CDN → `shared/config.js` → `supabase-client.js` → `auth-guard.js`. 새 페이지 UI는 `.miu-*`(layout.css) 규약, 헤더·뒤로가기는 `letter/*`를 본뜬다. 홈 `index.html`만 자체 인라인 CSS.
- 전역: `window.sb`(공용 클라이언트, 세션 localStorage 공유), `MIU_USER`, `MIU_PROFILE`(**`undefined`=로딩 중, `null`=실패**; 쓰기 전 `undefined` 동안 100ms 간격 폴링하는 관용구), `miuLoginName()`, `miuSetFixedName(select,name)`.
- 일부 페이지(`sold-report`, `turnover`, `item-scanner`)는 `window.sb` 대신 세션 `access_token`으로 REST/RPC를 직접 호출한다. 토큰 없으면 실패.
- 가드 없는 페이지: `login.html`, `design-system.html`, `move/compare-barcodes.html`(개발용, 비로그인 차단 후 동작 안 할 것 `[추정]`). `shared/config.js`의 `PUBLIC_PATHS`에 있는 `auth-callback.html`은 **파일이 없다**.
- `manifest.json`의 theme_color는 토큰·`index.html` 메타와 다르다.

## 4. 권한·DB 규칙
### 4.1 사람
- 로그인: 이메일 OTP(`?password=1`은 예비). `returnTo`는 `/miu-hub/…`만 허용. **가입은 닫힘**: 새 직원은 Supabase 대시보드 Authentication에서 초대. `profiles`는 자동 생성되지만 **이름이 비어 있으므로 통합 관리에서 이름을 넣어야** 한다. 이름이 없으면 **이동·가격수정 저장과 입고 승인**을 DB가 거절한다.
- `profiles.role` = `admin` / `employee`. `is_handler`는 담당자 드롭다운 노출. 역할·is_handler·email은 관리자만 변경(트리거 `protect_profile_privileged_columns`).
- **화면의 역할 체크는 UI일 뿐.** 로그인 직원은 허브 테이블·함수 전부 사용 가능(역할별 제한 없음, 입고 승인도 물류팀 누구나). 코드 상수 PIN(`dashboard`, `calendar`)은 권한 근거가 아니다.
- 비로그인(anon) 완전 차단. 예외는 `inventory_items`의 컬러 패턴 라벨 도구용 정책 2개뿐(`anon_color_tool_select/update`). 상세 `docs/DB_ACCESS_POLICY_20261025.md`.
- **황태훈 1명 전용**: `is_letter_admin()`(profile id 고정, `scripts/weekly-letters-admin-20261023.sql`). 범위를 넓히려면 이 함수만 고친다. 홈 타일 `#letter-status-tile`은 `#admin-section` 안이라 role=admin 이면서 `is_letter_admin()`일 때만 보인다. `status.html` 자체엔 클라이언트 게이트가 없고 RPC가 막는다.
- **최영훈·황태훈 전용 화면**: `logistics-request/`. 홈 타일(`index.html`)과 페이지(`ALLOWED_NAMES`) 두 곳에서 `MIU_PROFILE.name` 이 `['최영훈','황태훈']`에 드는지 클라이언트 체크뿐(서버 차단 아님; 데이터는 로그인 직원 공통 권한). 이름 변경·동명이인·대상 추가 시 두 곳을 같이 고친다.
- **category-analysis도 같은 두 사람 전용이며 서버가 강제**: `is_logistics_user()`(profile id 고정, `scripts/category-performance-20261027.sql`)가 RPC `category_performance`와 테이블 `store_hangers` RLS를 막는다. 홈 타일·페이지의 이름 체크(UI)는 별개이니 대상 변경 시 **함수 + 두 화면 + `logistics-request/`** 를 같이 고친다.
- **매장 업무(`manual/`): 직원 3명 + 관리자 2명만(서버가 강제)**: `is_store_staff()`(전수지·천현수·정경환)·`is_store_manager()`(황태훈·최영훈)가 profile id 고정(`scripts/store-manual-20261029.sql`). 5명 밖의 로그인 직원은 이 5개 테이블을 읽지도 못한다. 직원은 읽기 + RPC(`checklist_set`, `store_note_add`, `store_note_delete`)로만 쓰고, 관리자는 `manual_articles`·`checklist_items` 편집(RLS)과 메모 확인(`store_note_confirm`)·기간 현황(`store_checklist_overview`). 체크·메모는 (날짜, 매장) 단위로 같은 매장 직원이 공유하고 **서버 KST 오늘만** 기록된다(지난 날 수정 불가). 항목은 삭제 없이 `is_active=false`로 숨긴다. 항목의 `weekdays`(1=월…7=일, null=매일; `store-manual-weekdays-20261029.sql`)에 없는 요일엔 체크리스트·분모에서 빠진다(성수 마네킹 디피·스팀은 월·수·금).
- **매장 업무의 매장 목록 = `locations` 연동**: 성수 = 본점(근무자 항상 1명), 그 밖의 활성 위치 = 키오스크(무인 팝업) 근무자가 하루 한 번 도는 매장. 통합 관리에서 매장을 추가하면 자동으로 나타나고, 매장 현황판 "철수완료"(`is_active=false`)로 빠진다(과거 기록은 관리자 현황표에 "철수" 열로 남음). 매장이 아닌 위치만 `manual/common.js`의 `NON_STORE`(공동물류·온라인·폐기·재봉합부천·재봉합성수)로 걸러내므로 **새 비매장 위치를 만들면 거기에 추가**. 관리자 현황표에서 본점의 지난 날 빈 칸은 "미기록"(빨강), 키오스크 매장의 빈 칸은 근무자가 없는 날일 수 있어 중립 "—". 엑셀 원본에 있던 관리자번호·원격 접속 주소/입력값·리커버리 비밀번호는 공개 저장소라 시드에서 뺐고 해당 글(키오스크 분류)에 "매니저에게 문의"로 적어 둠 — 허브 편집 화면(`manual/admin.html`)에서 직접 채운다. 대상 인원 변경 시 **함수 `is_store_staff`/`is_store_manager`만** 고친다(화면은 `store_manual_role()` 결과로 분기).

### 4.2 서버가 강제 (화면 우회 불가; 로그인 직원에게만, service_role/VM은 예외)
- 입고 승인 = RPC `approve_inventory_session(uuid)` 한 번(바코드 발급+승인 기록 원자적, 동시 승인 직렬화, 승인자=로그인 이름).
- 승인 취소 보호: `printed_at` / `kiosk_exported_at` / `excel_updated`가 있으면 reopen 불가(트리거 `guard_reopen_inventory_session`).
- 대량 이동 = RPC `create_bulk_move_session(...)` 원자 저장, 날짜는 서버 KST.
- `move_sessions.created_by`, `session_items.scanned_by`, `price_changes.changed_by` = 로그인 이름으로 덮어씀(`force_login_name`). 대신 입력(관리자가 직원 대신)해도 입력한 사람 이름으로 남는다.
- 새 테이블·함수: RLS 켜고 `authenticated` 정책만, anon 권한 없음, **GRANT 명시 필요**(`docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md`; 주간 레터 SQL이 준수 예시).

### 4.3 저장소에 정의가 없는 운영 DB 객체
`profiles` 테이블, `is_admin()`, `next_barcode()`, `peek_next_barcode()`, `max_barcode_num()`, `handle_new_user()`, `sync_sold_status()`(sold_items AFTER INSERT 트리거). 변경·가정 전에 `pg_get_functiondef`로 조회한다.
- 읽기 전용 조회: `supabase db query --linked "<SQL>"` (운영 직결).
- `supabase/.temp/`(CLI 연결 상태)는 git 추적 밖(`.gitignore`). 새 기기·새 clone에서는 `supabase link --project-ref <프로젝트 id>`를 한 번 실행해야 `--linked`가 동작한다(비밀번호 불필요). 프로젝트 id는 `shared/config.js`의 Supabase URL 앞부분.
- 쓰기 SQL은 `scripts/<이름>-<날짜>.sql` 파일로 남기고 `supabase db query --linked -f`로 적용. 마이그레이션 이력 없음.
- 최신 SQL: `weekly-letters-admin-view-20261026`(레터 열람 현황 본문 보기; `letter_read_status` 재정의), `approve-inventory-session / bulk-move-and-reopen-guard / force-login-name / hardening-step2`(2026-10-25). `hardening-step2` 헤더는 "적용 전 초안"이지만 **적용 완료**. `item-scanner/supabase/schema.sql` 헤더의 "테스트 전용"은 낡았다(2026-09-03 `miu_ops` 단일 프로젝트 통합).
- 행거수: 테이블 `store_hangers`(매장·카테고리·적용일·행거수 **변경 이력**)가 원본. 기간 평균 행거수 = 그 기간 하루하루에 그날 유효한 값을 적용한 일수 가중 평균, 첫 입력일 이전 기간은 첫 값으로 채움. 초기값은 매니저 시트의 2026-10-27 현재 값(`category-performance-seed-20261027.sql`). 재고·재고 소진은 조회 기간이 아닌 **현재** `inventory_items` 기준이라 과거 기간과 시점이 어긋난다.
- 카테고리 통일: `PK`와 `PK셔츠`(`온PK`·`온PK셔츠`)는 혼용 입력이라 **같은 것**으로 본다. `norm_category()`(대소문자·공백 + PK→PK셔츠)가 `category_performance`에서, `logistics-request/`는 클라이언트에서 같은 규칙을 적용한다. `inventory_items` 원본 값은 그대로 둔다.
- Storage(모두 public 버킷): `inventory-photos`, `item-photos`, `letter-thumbs`(**쓰기는 service_role만**), `stocktake-reports`.
- 스테이징(`scripts/staging-setup/`)은 운영 스키마 덤프 복원용이며 RPC·트리거·item-scanner 테이블이 없다. `30-copy-seed-data.sh`는 운영 개인정보를 복사하니 주의.

## 5. 저장소 밖과 이어지는 흐름
`../work_automation/`(비공개, Oracle VM 크론, service_role). 정식 원본은 거기이며 VM 코드 변경은 거기서 먼저 커밋. 크론(KST): `move_update` 매분 · `inventory_process`·`price_update` 2분 · `sold_sync` 00:30 · `sales_sheet_sync` 01:00 · `auto_approve` 22:00 · `reconcile` 03:00 · `weekly_letter` 월 07:30 · `daily_sales_letter` 월~금 07:30.
- **입고**: 앱에서 승인(RPC가 바코드 발급) → VM `inventory_process`가 엑셀/시트 반영 후 `status=processed`, `excel_updated` → 라벨 출력(`printed_at`) / 키오스크 XLSX(`kiosk_exported_at`). 반영·출력 후엔 승인 취소 불가. 바코드: 공동물류 `A`+YY+6자리, 온라인 `U`+YYMM+4자리. 이전 날 pending 세션은 새 세션 화면 진입 때 비었으면 삭제·아니면 `expired`.
- **이동**: pending 저장 → 22:00 VM `auto_approve`가 오늘 pending을 approved → 매분 VM이 승인분 엑셀/Dropbox 반영. 판매 리포트는 approved만 쓴다. 화면에 승인 UI는 없다 `[수동 승인 경로 확인 못 함]`. 상태값: pending/approved/expired(+`processed`, `correction` 코드상 존재).
- **주간 레터**: VM `jobs/weekly_letter.py --all`(`run_weekly_letter.sh`)이 코드 상수 `LETTER_RECIPIENTS`(5명) 각자의 레터를 만들어 `weekly_letters`에 upsert(`on_conflict recipient_id,subject_name,week_start`, 재실행해도 `read_at` 유지)하고 썸네일을 `letter-thumbs`에 올린다. 판매 데이터가 해당 주 끝까지 없으면 중단.
  - **정식 발송** = `subject_name == 수신자 이름`. 미리보기 = 다른 사람 통계를 본인에게(`--subject X --recipient 황태훈`; 화면에 "미리보기" 배너). 열람 현황·`letter_admin_view`는 정식 발송분만.
  - 수신자가 처음 열면 `read_at` 기록. 황태훈이 열람 현황에서 `index.html?id=…&as=admin`으로 볼 땐 기록하지 않는다. 홈 레터 타일/팝업은 내게 온 `weekly_letters`(미리보기 포함)가 있을 때 뜬다.
- **판매 레터**: VM `jobs/daily_sales_letter.py`(`run_daily_sales_letter.sh`)가 코드 상수 `RECIPIENTS`(김민지)에게 `sales_letters`에 upsert(`on_conflict recipient_id,period_start,period_end`, 재실행해도 `read_at` 유지). 월요일=지난주 월~일 전체, 화~금=전날, 토·일 없음. 판매 0건이어도 "판매 없음" 레터를 보낸다. 환불(`refund_date`) 제외.
  - 대상 규칙(코드 `is_target`): 바코드 접두사(숫자 앞 글자)가 **정확히** `U, SB, YH, M, N, G, H, T, LOST, SEL, BIBLE, WW, WWA` / 카테고리 ETC(대소문자·"온" 무시, 접두사 무관) / `CR`+(ETC·모자) / `YGH`+모자. `MB·MA·MU·TT·HK`는 대상 아님.
  - 입고일 = 세션 `session_date`, 없으면(엑셀 일괄 반영분) `inventory_items.created_at`의 한국 날짜(운영상 검증된 값으로 취급). 매장 도착일 = 승인된 이동 중 판매 매장으로 간 마지막 이동일(`move_sessions.to_location`, 판매일 이전). 이동 기록이 없으면 "매장 이동 기록 없음".
  - 홈 "판매 레터" 타일은 본인 행이 있을 때만 뜬다(RLS). 수신자 변경은 코드 수정. 황태훈은 수신자가 아니며 `letter/status.html`의 "판매 레터" 섹션에서 열람 여부를 보고, "레터 보기"(`sales-letter/index.html?id=…&as=admin`)로 발송 내용을 읽기만 한다(`sales_letter_read_status()`·`sales_letter_admin_view()`, `is_letter_admin()` 게이트, `scripts/sales-letters-admin-20261029.sql`).
- **매출 리포트**: 키오스크 엑셀(영수증·카드·입고 시트)을 `report/js/*`가 파싱·조인·분석 → `sales_reports`/`sales_report_items`. 현금매출은 구글시트 `현금매출` 탭을 gviz로 읽는다. 열 위치·시트명 하드코딩이라 원본 포맷이 바뀌면 파싱부터 깨진다. 저장은 비원자적(항목 delete 후 insert 실패 시 항목 유실).
- `longterm/scripts/update_kiosk.py`(VM 키오스크 업로드)는 `kiosk_updates`를 폴링하지만 그 테이블은 사실상 미사용(미처리 553건 방치).
- `docs/POPUP_REPORT_ANALYSIS.md`는 팝업 매출 리포트의 옛 Streamlit 로직 분석(리포트 파이프라인 배경).

## 6. 알려진 함정·미결
- 큰 조회는 `.range()`/청크 필수(응답 1000행 한도, 초과하면 오류 없이 0처럼 보임; 대시보드 월 매출 미해결).
- `move/`: 이전 날 pending 정리를 클라이언트가 홈 로드 때 수행(경쟁 가능), 중복 검사는 DOM 기준, 단건 이동의 저장 오류 처리·제출 항목 삭제 방지 미흡(대량 이동만 보강).
- 재고조사 "현재 행거 미포함" 데이터 소실. 가격수정 큰 폭 변경 검증 없음. 바코드 UNIQUE 제약 없음(빈 바코드 선정리 필요). 분석 숫자 정의(대시보드·판매 리포트·매출 리포트) 통일 안 됨.
- `receiving/price-change.html`, `more.html`은 홈 메뉴 노출 여부 불명. `kiosk_updates`·`approvers`·`handlers`·`inventory_hangers.item_count`는 사실상 미사용(정리 후보).
- 카테고리 규칙: 분석에서 제외 C·위탁, `pb\d+` 바코드 제외, 이름이 '온'으로 시작하면 온라인, 외국 카드는 키워드 포함 여부로 판정.

## 7. 이력 (줄기만, 최신순)
- 2026-10-29 매장 업무(`manual/`, 홈 "매장 업무" 섹션, DB `manual_articles`·`checklist_items`·`checklist_days`·`checklist_checks`·`store_notes`). 매장직원 3명(전수지·천현수·정경환) 일일 체크리스트·특이사항 메모·상황별 대처 매뉴얼, 관리자 2명(황태훈·최영훈) 날짜별 현황·메모 확인·편집. 성수 본점/키오스크 매장 구분, 매장 칩+진행률, 항목 적용 요일. 운영 DB 적용 완료(`store-manual-20261029.sql` → `store-manual-seed-20261029.sql` → `store-manual-weekdays-20261029.sql`).
- 2026-10-28 판매 레터(`sales-letter/`, DB `sales_letters`, VM `daily_sales_letter` 평일 07:30).
- 2026-10-27 매장 매니저 전용 화면 2개(홈 "매장 매니저" 섹션): 물류요청 판매 집계 엑셀(`logistics-request/`), 카테고리 판매 분석+행거수 이력(`category-analysis/`, DB `store_hangers`·`category_performance`).
- 2026-10-26 레터 열람 현황에서 발송된 레터 읽기 전용 보기(`letter_admin_view`, `?as=admin`).
- 2026-10-25 보안 강화: 비로그인 차단, 입고 승인·대량 이동·승인 취소·담당자 서버 강제, returnTo 검증, 판매 리포트·회전율·item-scanner 세션 토큰 사용.
- 2026-10-23 주간 프라이싱 레터(홈 팝업, 판매 전체 보기, 썸네일 버킷, 열람 현황).
- 2026-09-30 매출 리포트에 현금매출(구글 시트) 통합.
- 2026-09-22 VM 자동화 정식 원본을 `work_automation`으로 이관.
- 2026-09-21 신규입고 A/U 자동 바코드, 통합 관리(admin), 캐시 버스팅.
- 2026-09-16 인증 시스템·디자인 리뉴얼·서브앱 통합. 2026-09-03 item-scanner를 `miu_ops` 단일 프로젝트로 통합.
