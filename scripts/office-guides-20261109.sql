-- 사무 업무 가이드(택 주문·시트지 주문·포스터 출력 등 사무실 업무를 단계별로 기록). 화면은 `office/`.
-- 적용: supabase db query --linked -f scripts/office-guides-20261109.sql
--
-- 구조: 가이드(업무 하나) → 단계(순서 있음) → 첨부(그 단계에서 쓰는 캡처 이미지·받을 파일).
-- 권한(서버 강제): 읽기 = 로그인 직원 전체, 쓰기 = is_admin(). 비로그인(anon)은 아무것도 못 한다.
-- 가이드 본문에는 주문 사이트 계정 같은 값이 들어갈 수 있다. 값은 허브 편집 화면에서만 입력하고 이 저장소(SQL·코드)에는 쓰지 않는다.
-- 첨부 파일은 비공개 버킷 office-files(임시 서명 URL로만 열림).

-- ── 테이블 ───────────────────────────────────────────────────
create table if not exists public.office_guides (
    id          uuid primary key default gen_random_uuid(),
    category    text not null check (btrim(category) <> ''),   -- 주문 / 출력 …
    title       text not null check (btrim(title) <> ''),
    summary     text not null default '',                       -- 언제 하는 일인가
    prepare     text not null default '',                       -- 준비물
    sort_order  integer not null default 0,
    is_active   boolean not null default true,
    updated_by  text,
    updated_at  timestamptz not null default now()
);
create index if not exists office_guides_cat_idx on public.office_guides (category, sort_order);

create table if not exists public.office_steps (
    id          uuid primary key default gen_random_uuid(),
    guide_id    uuid not null references public.office_guides(id) on delete cascade,
    sort_order  integer not null default 0,
    title       text not null check (btrim(title) <> ''),
    body        text not null default '',                       -- 평문. 줄바꿈 그대로, https:// 주소는 링크
    updated_by  text,
    updated_at  timestamptz not null default now()
);
create index if not exists office_steps_guide_idx on public.office_steps (guide_id, sort_order);

create table if not exists public.office_attachments (
    id          uuid primary key default gen_random_uuid(),
    step_id     uuid not null references public.office_steps(id) on delete cascade,
    kind        text not null check (kind in ('image', 'file')),
    path        text not null unique,                           -- 버킷 office-files 안의 경로
    name        text not null,                                  -- 화면·다운로드에 보이는 원래 파일 이름
    size_bytes  bigint,
    sort_order  integer not null default 0,
    created_by  text,
    created_at  timestamptz not null default now()
);
create index if not exists office_attachments_step_idx on public.office_attachments (step_id, sort_order);

-- 편집 기록(이름·시각)은 서버가 박는다. 서버 작업(service_role)은 이름 없이 통과.
create or replace function public.office_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is not null then
        new.updated_by := public.store_manual_name();
    end if;
    new.updated_at := now();
    return new;
end
$$;
drop trigger if exists office_touch on public.office_guides;
create trigger office_touch before insert or update on public.office_guides
    for each row execute function public.office_touch();
drop trigger if exists office_touch on public.office_steps;
create trigger office_touch before insert or update on public.office_steps
    for each row execute function public.office_touch();

create or replace function public.office_attachment_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is not null then
        new.created_by := public.store_manual_name();
    end if;
    return new;
end
$$;
drop trigger if exists office_attachment_touch on public.office_attachments;
create trigger office_attachment_touch before insert on public.office_attachments
    for each row execute function public.office_attachment_touch();

-- ── RLS ──────────────────────────────────────────────────────
alter table public.office_guides      enable row level security;
alter table public.office_steps       enable row level security;
alter table public.office_attachments enable row level security;

drop policy if exists office_guides_select on public.office_guides;
create policy office_guides_select on public.office_guides for select to authenticated using (true);
drop policy if exists office_guides_write on public.office_guides;
create policy office_guides_write on public.office_guides
    for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists office_steps_select on public.office_steps;
create policy office_steps_select on public.office_steps for select to authenticated using (true);
drop policy if exists office_steps_write on public.office_steps;
create policy office_steps_write on public.office_steps
    for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists office_attachments_select on public.office_attachments;
create policy office_attachments_select on public.office_attachments for select to authenticated using (true);
drop policy if exists office_attachments_write on public.office_attachments;
create policy office_attachments_write on public.office_attachments
    for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md)
revoke all on public.office_guides, public.office_steps, public.office_attachments from anon, authenticated;
grant select, insert, update, delete on public.office_guides, public.office_steps, public.office_attachments to authenticated;
grant select, insert, update, delete on public.office_guides, public.office_steps, public.office_attachments to service_role;

-- ── 첨부 저장소(비공개) ──────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit)
values ('office-files', 'office-files', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;

drop policy if exists office_files_select on storage.objects;
create policy office_files_select on storage.objects for select to authenticated using (bucket_id = 'office-files');
drop policy if exists office_files_insert on storage.objects;
create policy office_files_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'office-files' and public.is_admin());
drop policy if exists office_files_update on storage.objects;
create policy office_files_update on storage.objects for update to authenticated
    using (bucket_id = 'office-files' and public.is_admin()) with check (bucket_id = 'office-files' and public.is_admin());
drop policy if exists office_files_delete on storage.objects;
create policy office_files_delete on storage.objects for delete to authenticated
    using (bucket_id = 'office-files' and public.is_admin());
