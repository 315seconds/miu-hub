# Supabase Data API 자동 grant 중단 (2026-10-30)

메일 수신: 2026-10-20. 현재 운영 중인 앱은 영향 없음 (기존 테이블은 grant 유지).

## 변경 내용
- 2026-10-30부터 기존 프로젝트에서도 `public` 스키마에 **새로 만든 테이블**에 Data API 접근 권한이 자동 부여되지 않음.
- 명시적 `GRANT` 없이는 supabase-js / PostgREST / GraphQL이 `permission denied` 반환.
- 해당: 새 테이블 생성, 새 프로젝트, preview branch, 로컬 `supabase db reset`.

## 새 테이블 만들 때 규칙
같은 SQL 안에서 grant를 함께 작성:

```sql
grant select on public.<table> to anon;                                  -- anon이 필요할 때만
grant select, insert, update, delete on public.<table> to authenticated;
grant select, insert, update, delete on public.<table> to service_role;
-- identity/serial 컬럼이 있으면 시퀀스도:
grant usage, select on sequence public.<table>_id_seq to authenticated;
```

## 스키마 파일별 현황 (2026-10-21 점검)
| 파일 | 상태 |
|---|---|
| `item-scanner/supabase/schema.sql` (miu-hub 내부 포함) | anon grant 명시됨. 안전 |
| `miu-hub/scripts/staging-setup/15, 40, 60` | `40-rls-policies.sql`의 `ALTER DEFAULT PRIVILEGES`로 `authenticated` 커버. **순서(15→40→60), 같은 역할로 실행** 필요. `service_role` grant 없음 |
| `strength-log/supabase/schema.sql` | grant 없음. 새 프로젝트/`db reset` 시 보완 필요 |
| `miu-hub/archive-review/setup.sql` | grant 없음. 새 프로젝트/`db reset` 시 보완 필요 |

## 보완이 필요해지는 시점
- staging 등 새 환경을 만들 때: service key로 접근하는 서버/봇이 있으면 `service_role` grant 추가.
- `strength-log`, `archive-review` 스키마로 새 프로젝트를 만들거나 `db reset`할 때: grant 추가.
- 위 경우가 없으면 조치 불필요.
