-- store_daily_receipts 에 국내/해외 열 추가 (VM 작업 kiwoom_receipts_daily.py 가 카드 승인 내역의 발급사명으로 나눠 채운다)
-- 적용: supabase db query --linked -f scripts/store-daily-receipts-split-20261104.sql   (store-daily-receipts-20261104.sql 이 먼저 필요)
--
-- 해외 = 알리페이·위챗페이 + 발급사명에 해외 키워드(해외·오렌지스퀘어·중국·아이오로라·한패스)가 든 카드. 허브 매출 리포트의 해외 판정과 같은 규칙.
--   foreign_net / domestic_net = 카드·QR 순매출을 둘로 나눈 값(현금은 키오스크 전표가 없어 없다), *_purchases = 구매 건수를 둘로 나눈 값.
--   unclassified_* = 카드로 결제했는데 카드 승인 내역과 못 이은 몫(정상이면 0).
-- 카드 파일을 못 받은 날은 null 로 둔다(0이 아니다). 영수증 열과 따로 upsert 하므로 카드 수집 실패가 기존 값을 지우지 않는다.

alter table public.store_daily_receipts
    add column if not exists foreign_purchases      integer,
    add column if not exists domestic_purchases     integer,
    add column if not exists unclassified_purchases integer,
    add column if not exists foreign_net            bigint,
    add column if not exists domestic_net           bigint,
    add column if not exists unclassified_net       bigint;
