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

-- 완료된 항목의 사진을 재촬영해서 교체할 때, 클라이언트(anon)가 이전 사진 파일을
-- 직접 지울 수 있어야 한다(안 지우면 사진이 계속 쌓여 storage 용량 문제가 재발함).
drop policy if exists "anon can delete item photos" on storage.objects;
create policy "anon can delete item photos"
  on storage.objects for delete
  to anon
  using (bucket_id = 'item-photos');
