-- item-scanner 테스트 프로젝트의 사진 저장 버킷 설정.
-- 촬영한 상품 사진은 민감정보가 아니므로 public 버킷으로 만들어
-- 엑셀 내보내기의 "원본 열기" 링크(getPublicUrl)가 그대로 동작하게 한다.

insert into storage.buckets (id, name, public)
values ('item-photos', 'item-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "anon can upload item photos" on storage.objects;
create policy "anon can upload item photos"
  on storage.objects for insert
  to anon
  with check (bucket_id = 'item-photos');
