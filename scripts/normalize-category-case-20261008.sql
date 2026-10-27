-- inventory_items.category 영문 대소문자 통일 (2026-10-08)
-- 대상: 아래 6개 값만 정확히 일치하는 행 (날짜/범위 조건 없음). 예상 합계 = 871건
-- 실행: Supabase SQL Editor (프로덕션 miu_ops) 에서 블록 단위로 실행

-- 1) 백업 + 건수 확인 (예상: etc 331 / c 187 / 온etc 128 / 온pk 131 / Pk 66 / pk 28)
create table if not exists public.bak_inventory_category_case_20261008 as
select id, category from public.inventory_items
where category in ('etc','c','온etc','온pk','Pk','pk');

select category, count(*) from public.bak_inventory_category_case_20261008 group by 1 order by 2 desc;

-- 2) 변환 (백업 id 기준, 트랜잭션)
begin;
update public.inventory_items i
set category = case b.category
  when 'etc'   then 'ETC'
  when 'c'     then 'C'
  when '온etc' then '온ETC'
  when '온pk'  then '온PK'
  when 'Pk'    then 'PK'
  when 'pk'    then 'PK'
end
from public.bak_inventory_category_case_20261008 b
where i.id = b.id and i.category = b.category;   -- 그 사이 값이 바뀐 행은 건드리지 않음
-- 결과가 871 근처인지 확인 후 commit; 아니면 rollback;
commit;

-- 롤백이 필요하면:
-- update public.inventory_items i set category = b.category
-- from public.bak_inventory_category_case_20261008 b where i.id = b.id;
