-- 빈티지 아카이브 평가 앱 — Supabase 새 프로젝트에서 SQL Editor로 실행

-- 1. 사진 메타데이터
create table archive_photos (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null,
  public_url text not null,
  uploaded_at timestamptz not null default now()
);

-- 2. 직원별 평가 (한 직원당 한 사진에 1개 — 재제출 시 upsert로 덮어씀)
create table photo_ratings (
  id uuid primary key default gen_random_uuid(),
  photo_id uuid not null references archive_photos(id) on delete cascade,
  employee_name text not null,
  score smallint not null check (score between 1 and 10),
  feedback text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (photo_id, employee_name)
);

-- 3. 로그인 없는 내부 툴이라 anon 키로 전체 read/write 허용
alter table archive_photos enable row level security;
alter table photo_ratings enable row level security;

create policy "anon full access" on archive_photos for all using (true) with check (true);
create policy "anon full access" on photo_ratings for all using (true) with check (true);

-- 4. 사진 저장용 Storage 버킷 (공개 읽기 + 익명 업로드)
insert into storage.buckets (id, name, public)
values ('archive-photos', 'archive-photos', true);

create policy "anon read photos" on storage.objects for select using (bucket_id = 'archive-photos');
create policy "anon upload photos" on storage.objects for insert with check (bucket_id = 'archive-photos');
