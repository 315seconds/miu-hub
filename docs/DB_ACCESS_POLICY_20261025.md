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
옛 DB 웹훅 `move-approved`(옛 서버 `43.202.62.74:8080`으로 전송, 비밀값이 공개 저장소 기록에 노출됨)는 제거했다.

## 새 테이블·함수를 만들 때
- RLS를 켜고 `authenticated` 정책만 만든다. `anon`에는 권한을 주지 않는다.
- 이 정책 적용 시 기본 권한(`alter default privileges`)에서 anon 자동 부여를 막아 두었다.
- 점검 SQL: `pg_policies`에서 `anon`/`public` 대상 정책이 `inventory_items`의 2개뿐인지, `information_schema.role_table_grants`에서 anon 권한이 `inventory_items`뿐인지 확인한다.

## 되돌리기
복원 SQL은 비밀값(옛 웹훅 헤더)이 들어 있어 저장소에 두지 않았다. 작업 PC `~/miu-backup/hardening-step2-RESTORE.sql`에 있다.
