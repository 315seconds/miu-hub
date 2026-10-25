# DB 접근 정책 (2026-10-25 적용)

운영 Supabase 프로젝트(`miu_ops`)의 접근 권한을 정리한 기록이다. 적용 SQL은 `scripts/hardening-step2-20261025.sql`.

## 지금의 규칙
- **비로그인(공개 키)은 아무것도 못 한다.** 읽기, 쓰기, 삭제, 함수 실행, 사진 저장소 업로드·목록이 모두 막혀 있다.
- **로그인한 직원**은 허브가 쓰는 테이블과 함수를 모두 쓸 수 있다. (역할별 제한은 아직 없다. 입고 승인은 물류팀 누구나 가능한 운영 방식.)
- **등급(`profiles.role`), 담당자 여부, 이메일은 관리자만 바꿀 수 있다.** DB 트리거 `protect_profile_privileged_columns`가 강제한다.
- **회원가입은 닫혀 있다.** 새 직원은 Supabase 대시보드 `Authentication → Users → Add user / Invite user`로 등록한다. 등록하면 `profiles`는 자동 생성된다.
- Auth의 Site URL은 `https://315seconds.github.io/miu-hub/`.
- `approvers` 테이블은 로그인 직원에게도 막혀 있다(코드에서 쓰지 않음, PIN 평문).

## 유일한 비로그인 예외 (컬러 패턴 라벨 도구)
`315seconds.github.io/color-pattern-label`이 로그인 없이 동작하도록 `inventory_items`에만 예외를 둔다.
- 읽기: `status = 'in_stock'` 행 (가격 포함)
- 쓰기: 색상이 비어 있는 판매 중 상품의 `color`, `pattern` 컬럼만
- 도구를 허브에 편입하면 이 예외(`anon_color_tool_select`, `anon_color_tool_update`와 `grant select/update` 두 줄)를 삭제한다.

## 서버(VM) 자동화
VM 작업은 service_role 키를 쓰므로 위 규칙과 무관하게 동작한다. 이동 승인 반영은 DB 웹훅이 아니라 VM이 매분 확인하는 방식이다.
쓰지 않는 옛 DB 웹훅(`move-approved`)은 제거했다.

## 새 테이블·함수를 만들 때
- RLS를 켜고 `authenticated` 정책만 만든다. `anon`에는 권한을 주지 않는다.
- 이 정책 적용 시 기본 권한(`alter default privileges`)에서 anon 자동 부여를 막아 두었다.
- 점검 SQL: `pg_policies`에서 `anon`/`public` 대상 정책이 `inventory_items`의 2개뿐인지, `information_schema.role_table_grants`에서 anon 권한이 `inventory_items`뿐인지 확인한다.

## 되돌리기
복원 SQL에는 민감한 값이 들어 있어 저장소에 두지 않고 작업 PC에 따로 보관한다.

## 서버가 강제하는 규칙 (같은 날 추가)
화면에서만 막는 것이 아니라 DB가 직접 강제한다. 로그인 직원(`authenticated`)에게만 적용되고, 서버 자동화(`service_role`)는 예외다.
- **입고 승인**: `approve_inventory_session(uuid)` 한 번의 호출로 바코드 발급, 상품 갱신, 승인 기록이 모두 성공하거나 모두 취소된다. 승인은 한 번에 하나씩 처리되고, 이미 승인된 세션은 거절된다. 승인자는 로그인한 계정 이름으로 자동 기록된다. (`scripts/approve-inventory-session-20261025.sql`)
- **승인 취소 보호**: 라벨 출력, 키오스크 파일 다운로드, 엑셀 기록이 있는 세션은 승인을 취소할 수 없다. 대량 이동은 `create_bulk_move_session(...)`로 세션과 항목을 한 번에 저장한다. (`scripts/bulk-move-and-reopen-guard-20261025.sql`)
- **담당자 고정**: 이동 세션(`created_by`), 이동 스캔(`scanned_by`), 가격수정(`changed_by`)은 로그인한 계정 이름으로 저장된다. 이름이 없는 계정은 저장이 거절되므로, 새 직원은 통합 관리에서 이름을 먼저 설정한다. (`scripts/force-login-name-20261025.sql`)
