-- 색상·패턴 야간 자동 라벨링(맥미니 leo_label_auto/nightly.py)의 대상 조회용 부분 인덱스.
-- 조회: inventory_items?photo_url=not.is.null&color=is.null&status=eq.in_stock&order=id&limit=1000
-- 인덱스가 없으면 id 순서로 8만 행을 전부 훑어(약 84,000 버퍼) anon 계정 statement_timeout=3s에 걸린다
-- (2026-11-07·08 19:00 KST 57014로 500). 인덱스가 있으면 대상 행(수백 건)만 읽는다.
-- 대상이 아닌 행은 인덱스에 들어가지 않아 쓰기 부담은 거의 없다. 되돌리기: drop index public.inventory_items_color_todo_idx;
create index if not exists inventory_items_color_todo_idx
  on public.inventory_items (id)
  where photo_url is not null and color is null and status = 'in_stock';
