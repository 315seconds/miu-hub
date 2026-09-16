# 스테이징 환경 셋업 가이드

이 폴더는 프로덕션 miu_ops 스키마를 별도 스테이징 프로젝트로 복제해서, 로그인/RLS 실험을 안전하게 하기 위한 도구입니다.

## 준비물 (사장님이 해줄 것)

### 1. Supabase에서 새 스테이징 프로젝트 생성

1. https://supabase.com/dashboard 접속
2. 조직 선택 → "New Project"
3. 이름: `miu-ops-staging` (아무거나 OK)
4. Region: `Northeast Asia (Seoul)` 권장 (프로덕션과 동일)
5. DB Password: **강력한 비번 생성해서 어딘가 저장** (한 번 놓치면 재설정만 가능)
6. Plan: Free

### 2. 두 프로젝트의 접속정보 수집

**프로덕션 (기존)**
- Supabase Studio → 프로젝트 선택 → Settings → Database
  - Host: `db.yqnocnzjrcsrwrvsvsyg.supabase.co`
  - Password: [프로덕션 DB 비번]
- Settings → API
  - anon key: (이미 코드에 있음)
  - service_role: (이미 `.env`에 있음)

**스테이징 (신규)**
- Settings → Database → Host + Password 복사
- Settings → API → URL, anon key, service_role 복사

### 3. `.env.staging` 생성

이 폴더에 `.env.staging` 파일 만들고 아래처럼 채우세요:

```bash
# 프로덕션 (읽기 전용으로만 사용)
PROD_DB_HOST=db.yqnocnzjrcsrwrvsvsyg.supabase.co
PROD_DB_PASSWORD=<프로덕션 DB 비번>

# 스테이징 (여기로 복제)
STAGING_DB_HOST=db.<staging-ref>.supabase.co
STAGING_DB_PASSWORD=<스테이징 DB 비번>
STAGING_URL=https://<staging-ref>.supabase.co
STAGING_ANON_KEY=<스테이징 anon key>
STAGING_SERVICE_ROLE_KEY=<스테이징 service_role key>
```

**주의**: `.env.staging`도 gitignore(`*.env`)에 걸려 있어 커밋되지 않음. 안전.

## 실행 순서

```bash
cd scripts/staging-setup

# 1. pg_dump 툴 있는지 확인 (macOS: brew install libpq)
./00-check-prereqs.sh

# 2. 프로덕션 스키마만 덤프 (데이터 X)
./10-dump-prod-schema.sh
# → out/prod-schema.sql 생성

# 3. 스테이징에 스키마 restore
./20-restore-to-staging.sh
# → 스테이징 DB에 18 테이블 + RPC 3개 재현됨

# 4. (선택) 소량 시드 데이터 복사
./30-copy-seed-data.sh
# → 각 테이블 앞 100~500행만
```

## 트러블슈팅

- **pg_dump: command not found** → macOS: `brew install libpq && brew link --force libpq`
- **connection timeout** → Supabase Studio에서 IP 화이트리스트 확인 (기본은 열려있음)
- **permission denied on schema public** → 스테이징 프로젝트가 완전히 프로비저닝될 때까지 1~2분 대기
