-- 주간 레터용 사진 썸네일 버킷.
-- Supabase Storage Image Transformations(원본 이미지 수 과금)를 쓰지 않고,
-- work_automation/jobs/weekly_letter.py가 미리 줄인 JPEG를 올려 서빙한다.
-- 공개 읽기(원본 inventory-photos와 동일), 쓰기는 service_role만(RLS 우회).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('letter-thumbs', 'letter-thumbs', true, 1048576, array['image/jpeg'])
on conflict (id) do nothing;
