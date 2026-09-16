# popup_report 도메인 로직 분석 (2026-09-15)

Streamlit 앱 두 개(`raw_builder.py` 377줄 + `app.py` 665줄) 완전 분석.
JS 포팅을 위한 도메인 규칙 정리.

## 전체 데이터 흐름

```
[3종 파일 입력]
  ├─ 영수증.xlsx (키오스크당 1개) — 품목·바코드 내역
  ├─ 카드.xlsx    (키오스크당 1개) — 카드 승인 내역
  └─ 입고.xlsx    (1~2개)          — raw 데이터 (지점의 재고 마스터)

[STEP 1: raw_builder.py] 로우파일 생성
  ↓ 조인 · 아이템→바코드 매칭 · QR결제 합산
  → 판매분석.xlsx (거래데이터 시트 + 입고 시트)

[STEP 2: app.py] 리포트 생성
  ↓ 해외/온라인 분류 · 시간대 집계 · 카테고리 TOP3
  → popup_report.html + meta.json

[STEP 3: publish shell] GitHub 저장소 push
  → docs/main/YYYY-MM_store/ 또는 docs/popup/START_END_store/
  → GitHub Pages 자동 배포
```

## 🔵 STEP 1: raw_builder.py — 파일 조인

### 입력 파일 스키마

**영수증.xlsx** (키오스크 원본, 스키마가 좀 이상함):
- 트랜잭션 시작 행: col0=날짜, col6(또는 col5)=전표번호(숫자)
- 아이템 행: col1=순번(숫자), col2=순번(숫자), col4(또는 col5)=바코드
- 결제 행: col1=숫자, col2=결제수단 텍스트, col4=금액
- **파싱 로직**: `detect_col_positions()`가 헤더 스캔해서 `slip_col`, `barcode_col` 자동 감지

**카드.xlsx**:
- col2 = 숫자 필터 (거래 행 판별)
- col3 = 전표번호
- col5 = 카드발급사명
- col6 = 승인금액
- col10 = 거래일시

**입고.xlsx**:
- 시트명 = `"입고"`
- 열: `바코드`, `상품명`, `금액` (그 외 열 있음)

### 조인 로직

```python
# 1. 영수증 파싱 → 전표번호별 트랜잭션
# 2. 카드 파싱 → 전표번호별 카드 정보
# 3. merge(영수증, 카드, on=["날짜","전표번호"])
# 4. QR결제(알리페이/위챗페이)는 카드파일에 없으므로 별도 추가:
#    - 영수증에서 결제수단 in {"알리페이","위챗페이"}인 것 찾아서
#    - 카드 승인정보 대신 "결제수단"을 "카드발급사명"에 넣고
#    - 거래일시는 "YYYY-MM-DD 12:00:00"으로 설정 (정보 부족)
# 5. 정렬 by 거래일시
```

### 두 달 입고 파일 합치기 (팝업 케이스)

**핵심 로직** (팝업이 8월 중순~9월 중순에 진행된 경우):
```python
# 8월 입고 파일 (prev): 8월에는 있었지만 9월에 팔려서 9월 입고에 없는 물건
# 9월 입고 파일 (main): 9월 시점의 재고 마스터

df_main = load_ingo(main_f)           # 기준 파일
df_prev = load_ingo(prev_f)           # 이전 파일
bc_main = set(df_main["바코드"])
only_prev = df_prev[~df_prev["바코드"].isin(bc_main)]  # main에 없는 것만
result = concat(df_main, only_prev)   # 소급 추가

# 즉: 8월 파일에 있었지만 9월 파일에서 사라진 물건 = 8월 중 팔림 → 소급 복원
```

### 아이템명 → 바코드 매칭 (build_resolve_fn)

키오스크 영수증의 "아이템" 필드가 바코드가 아닌 **상품명** 텍스트인 경우 처리:

```python
def resolve(raw_text, tx_amount, n_items):
    # 1. 이미 바코드 형식이면 그대로: 정규식 ^[A-Za-z0-9\-]+$
    # 2. 알파숫자 접두어만 있으면 그 부분만: 예 "C123 나이키 티" → "C123"
    # 3. 입고 시트의 상품명으로 정확 매칭
    # 4. 안 되면 단어별 키워드 검색 (모든 단어가 포함된 것)
    # 5. 여러 개 매칭 시:
    #    - n_items=1이면 tx_amount와 금액 일치하는 것
    #    - 아니면 첫 번째
    # 6. 매칭 실패 → "[미매칭]원본텍스트"
```

## 🔵 STEP 2: app.py — 리포트 생성

### 입력: 판매분석.xlsx
- `거래데이터` 시트: `거래일시`, `지점명`, `승인금액`, `카드발급사명`, `구매바코드1`, `구매바코드2`, ...
- `입고` 시트: 열 C=입고일, D=상품명, E=금액, G=바코드, H=소분류

### 해외 카드 판정 ⭐ (사장님이 강조한 부분)

```python
DEFAULT_FOREIGN_KEYWORDS = ["해외", "오렌지스퀘어", "알리페이", "위챗페이"]

# 판정 로직: 카드발급사명에 키워드 중 하나라도 포함되면 해외
pattern = "|".join(keywords)
tx["해외여부"] = tx["카드발급사명"].str.contains(pattern, na=False)
```

**정말 단순한 문자열 매칭** — 사장님 말씀대로 복잡한 로직 없음.

키워드 목록은 사이드바에서 편집 가능 (JSON 저장/불러오기).

### 온라인 판정

```python
def cat_flags(raw_cat):
    is_online = raw_cat.startswith("온")  # 소분류 앞글자가 "온"
    base = raw_cat[1:] if is_online else raw_cat  # 표시할 때 "온" 제거
    return base, is_online

# 예: "온PK" → base="PK", is_online=True
```

### 카테고리 제외 규칙

```python
def is_excluded_category(base_cat):
    return base_cat in {"C", "위탁"}

# 그리고 바코드가 "pb숫자" 패턴(pb2, pb3 등)이면 소모품으로 판단해서 제외
# 정규식: ^pb\d+$
```

### 아이템별 매출 배분 (explode_items)

한 트랜잭션에 여러 물건이 있을 때 승인금액을 어떻게 나누나:

```python
# 입고 시트에서 바코드 → 금액 price_map 구축
# 동일 바코드에 여러 입고가 있으면 최근 입고일 기준

# 트랜잭션의 각 아이템에 대해:
if 모든_바코드가_price_map에_있음:
    # 비율 스케일링: 각 입고금액 × (승인금액 / 입고금액합)
    scale = approved / known_sum
    result = [p * scale for p in prices]
else:
    # 일부 미매칭
    # 매칭된 것: 입고금액 그대로
    # 미매칭: 잔액을 균등 배분
    fallback = (approved - known_sum) / unknown_count
```

### 시간대별 집계 (build_hourly)

```python
# 거래일시.hour로 그룹핑
# 24시간 모두 채움 (없는 시간대는 0)
# 국내/해외 분리
# 반환: {hour: [0..23], 총매출, 국내매출, 해외매출, 거래건수}
```

### 카테고리 TOP3 (6종)

```python
# 필터 조합 × 3 = 6개 표
# (overseas: None/False/True) × (online: False/True)

for combo in [
    ("all_gen",  None, False),   # 전체 · 일반
    ("all_on",   None, True),    # 전체 · 온라인
    ("dom_gen",  False, False),  # 국내 · 일반
    ("dom_on",   False, True),   # 국내 · 온라인
    ("for_gen",  True, False),   # 해외 · 일반
    ("for_on",   True, True),    # 해외 · 온라인
]:
    # 필터링 후 카테고리별 count/추정매출 집계
    # 상위 3개 반환 (count desc, 매출 desc)
```

### 피크타임 (peak_hour)

```python
# 시간대별 승인금액 합계 최대인 시각
# 국내/해외 각각 산출
```

### 리포트 HTML 구조

- Hero: 지점명, 기간, 5개 KPI (총매출, 총거래, 국내비중, 해외비중, 객단가)
- 요약: 4줄 텍스트 + 해외 키워드 뱃지
- 국내 vs 해외: 시간대 차트 2개 (matplotlib PNG base64 인라인)
- 카테고리 TOP3: 6개 표
- (선택) 지도: 위치 iframe

### meta.json (리포트와 별도)

```json
{
  "store": "성수", "start": "2026-08-15", "end": "2026-09-10",
  "days": 27,
  "total_sales": 12345000, "total_cnt": 234,
  "daily_avg_sales": 457222,
  "dom_sales": 10000000, "dom_cnt": 180, "dom_share": 0.81,
  "for_sales": 2345000, "for_cnt": 54, "foreign_share": 0.19,
  "peak_hour": 15, "peak_sales": 890000,
  "top_category": "액세서리",
  "foreign_keywords": [...],
  "location": "서울 마포구"
}
```

## 🔵 STEP 3: publish shell — GitHub 배포

**publish_popup_report.sh**:
```bash
# 폴더명 자동: {start}_{end}_{store 슬러그}
# 예: 2026-08-15_2026-09-10_gangnam
# docs/popup/{FOLDER}/index.html, meta.json 복사
# docs/popup/manifest.json 자동 업데이트 (append)
# git add + commit + push
```

**publish_main_report.sh**:
```bash
# 레이블 자동: start 날짜의 YYYY-MM
# 폴더명: {YYYY-MM}_{store}
# 예: 2026-08_seongsu
# docs/main/{FOLDER}/, manifest 업데이트
# git push
```

## 📌 JS 포팅 관점의 복잡도 평가

### 실제로 어려운 것 (신중 필요)
1. **영수증.xlsx 파싱** — 컬럼 자동 감지, 트랜잭션 경계 판별 (Python 고유 로직)
2. **바코드 매칭 (build_resolve_fn)** — 상품명 → 바코드 자동 매칭 (5단계 fallback)
3. **매출 배분 (explode_items)** — 미매칭 처리, 비율 스케일링
4. **입고 두 달 합치기** — set 연산 정확도

### 쉬운 것 (사장님 예상대로 단순)
1. **해외 판정** — 키워드 문자열 contains 매칭
2. **온라인 판정** — 첫 글자가 "온"인지
3. **카테고리 제외** — {C, 위탁} + `pb숫자` 패턴
4. **시간대 집계** — groupby hour, sum
5. **TOP3** — sort by count desc, head 3
6. **피크타임** — argmax hour by sum

### 라이브러리 매핑 (Python → JS)

| Python | JavaScript |
|---|---|
| `pandas.read_excel` | **SheetJS (xlsx)** |
| `pandas.DataFrame` | 배열 + object literal (or arquero, danfojs) |
| `groupby / agg` | `Array.reduce / d3.rollup` |
| `matplotlib` | **Chart.js** (miu-hub-auth-test 이미 사용 중) |
| `openpyxl` (Excel 저장) | SheetJS write |
| `st.download_button` | `<a download>` blob URL |
| `st.file_uploader` | `<input type="file">` |
| `st.session_state` | localStorage |
| Streamlit UI | 우리 miu 컴포넌트 |

### 서버 필요 여부
- **모두 브라우저에서 처리 가능**
- 파일 업로드 → SheetJS 파싱 → 인메모리 처리 → 결과 저장
- Supabase는 결과 저장·조회만 (raw 파일도 Storage에 백업 가능)

## 🎯 이관 후 개선 아이디어

지금 로직은 **10년 사용해도 안 바뀔 안정된 도메인 규칙**이라 그대로 옮기고, UX만 대폭 개선:

1. **단일 화면 워크플로**: raw_builder + app.py를 한 페이지로 합침 (지금은 앱 2개 순차 실행)
2. **매장 프리셋**: 성수/무성/연무장 등 지점명 자동 선택
3. **파일 오류 즉시 피드백**: 잘못된 파일 형식이면 어느 파일이 문제인지 표시
4. **DB 저장**: 매출 리포트를 Supabase에 저장 → 나중에 대시보드에서 시계열 비교
5. **저장된 리포트 목록**: `report/` 페이지가 GitHub Pages 대신 DB 조회
6. **키워드 관리**: 지금 사이드바 → 별도 설정 페이지
7. **자동 저장**: 파일 업로드 → 결과 자동 저장 → 리포트 URL 즉시 발급

## 다음 단계 제안

**Phase 1 (지금 완료)**: 도메인 로직 분석 → 이 문서

**Phase 2 (다음)**: DB 스키마 설계
- `sales_reports` 테이블: 리포트 메타 (store, start, end, kpi들, meta.json 통째로 저장 가능)
- `sales_report_items` 테이블(선택): 개별 아이템 매출 (dashboard 시계열 분석용)
- Storage 버킷: `sales-reports-raw`(원본 xlsx 백업), `sales-reports-generated`(생성된 HTML)

**Phase 3**: UI 프로토타입
- `report/upload.html` (파일 업로드 + 지점/기간 설정)
- `report/preview.html` (파싱 결과 미리보기, 저장 전 검증)
- `report/[id].html` (저장된 리포트 표시)

**Phase 4**: SheetJS + JS 로직
- 영수증 · 카드 · 입고 파서
- 조인 로직 (raw_builder 이관)
- 집계 · 분류 로직 (app.py 이관)
- 차트 (Chart.js)

**Phase 5**: 검증
- 기존 리포트와 숫자 대조 (성수 최근 몇 달, 팝업 몇 개)
- 오차 발생 원인 추적 · 수정

**Phase 6**: 롤아웃
- 매니저 테스트
- 기존 sales_report GitHub 저장소 아카이브
