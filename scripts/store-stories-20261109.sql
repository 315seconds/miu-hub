-- 인스타 스토리 이미지 (성수 본점이 매일 올리는 "신규 입고"와 키오스크 매장별 "All Set for Today!")
-- 적용: supabase db query --linked -f scripts/store-stories-20261109.sql   (store-manual-20261029.sql 이 먼저 적용돼 있어야 함)
--
-- 흐름:
--   · 키오스크 매장 근무자가 허브 `manual/`에서 정리 완료 사진을 올린다(오늘 KST만, 매장당 하루 1장·마지막 업로드가 남음, 22:00 KST 마감).
--   · VM 크론(`work_automation/jobs/story_images.py`, service_role)이 신규 입고(06:00)·정리 완료(22:10) 이미지를 만들어 같은 버킷에 올리고 story_images 에 기록한다.
--   · 성수 체크리스트 카드가 story_images 를 읽어 이미지를 보여 주고 받게 한다.
-- 권한(서버 강제): 읽기·업로드 = 매장 업무 직원·관리자(store_manual_can_use()). 합성 결과(out/)와 story_images 쓰기 = service_role 만.
-- 버킷 store-stories 는 비공개(임시 서명 URL로만 열림). 경로는 모두 ASCII:
--   photos/<날짜>/<uuid>.jpg · out/new_arrivals/<날짜>.jpg · out/all_set/<날짜>/<영문 슬러그>.jpg

-- ── 테이블 ───────────────────────────────────────────────────
create table if not exists public.store_photos (
    work_date   date not null,
    store       text not null,                                  -- locations.name
    path        text not null,                                  -- 버킷 store-stories 안의 경로
    uploaded_by text not null,
    uploaded_at timestamptz not null default now(),
    primary key (work_date, store)
);

create table if not exists public.story_images (
    kind        text not null check (kind in ('new_arrivals', 'all_set')),
    work_date   date not null,
    store       text not null default '',                       -- new_arrivals = '', all_set = locations.name
    path        text not null,
    number      integer,                                        -- new_arrivals 에 찍힌 숫자
    created_at  timestamptz not null default now(),
    primary key (kind, work_date, store)
);

alter table public.store_photos  enable row level security;
alter table public.story_images  enable row level security;
drop policy if exists store_photos_select on public.store_photos;
create policy store_photos_select on public.store_photos for select to authenticated using (public.store_manual_can_use());
drop policy if exists story_images_select on public.story_images;
create policy story_images_select on public.story_images for select to authenticated using (public.store_manual_can_use());

-- grant 규칙(docs/SUPABASE_DATA_API_GRANT_CHANGE_20261030.md): 읽기만 열고, 쓰기는 RPC(photos)·service_role(out)로만
revoke all on public.store_photos, public.story_images from anon, authenticated;
grant select on public.store_photos, public.story_images to authenticated;
grant select, insert, update, delete on public.store_photos, public.story_images to service_role;

-- ── 저장소(비공개) ───────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('store-stories', 'store-stories', false, 10485760, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['image/jpeg'];

drop policy if exists store_stories_select on storage.objects;
create policy store_stories_select on storage.objects for select to authenticated
    using (bucket_id = 'store-stories' and public.store_manual_can_use());
-- 직원 업로드는 photos/ 아래만. out/ 은 service_role(정책 우회)만 쓴다. 수정·삭제 정책 없음(정리는 VM이 한다).
drop policy if exists store_stories_insert on storage.objects;
create policy store_stories_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'store-stories' and public.store_manual_can_use()
                and (storage.foldername(name))[1] = 'photos');

-- ── 정리 완료 사진 기록 RPC ──────────────────────────────────
-- 사진 파일을 먼저 photos/<오늘>/<uuid>.jpg 로 올린 뒤 호출한다. 같은 날 다시 호출하면 마지막 사진으로 바뀐다.
-- 22:00 KST 이후는 거절한다(22:10 합성에 안 들어가는 사진을 받은 것처럼 보이지 않게).
create or replace function public.store_photo_set(p_store text, p_path text)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_today date := public.store_today();
begin
    if not public.store_manual_can_use() then
        raise exception '권한이 없어요.' using errcode = '42501';
    end if;
    if p_store is null or p_store = '성수'
       or not exists (select 1 from public.locations l where l.name = p_store and l.kind = 'store' and l.is_active) then
        raise exception '사진을 올릴 수 없는 매장이에요.' using errcode = 'P0001';
    end if;
    if (now() at time zone 'Asia/Seoul')::time >= time '22:00' then
        raise exception '오늘 사진 마감(22시)이 지났어요.' using errcode = 'P0001';
    end if;
    if p_path is null or p_path !~ ('^photos/' || v_today::text || '/[0-9a-f-]{36}\.jpg$') then
        raise exception '사진 경로가 올바르지 않아요.' using errcode = 'P0001';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'store-stories' and o.name = p_path) then
        raise exception '올린 사진 파일을 찾지 못했어요. 다시 올려 주세요.' using errcode = 'P0001';
    end if;
    insert into public.store_photos (work_date, store, path, uploaded_by, uploaded_at)
    values (v_today, p_store, p_path, public.store_manual_name(), now())
    on conflict (work_date, store) do update
        set path = excluded.path, uploaded_by = excluded.uploaded_by, uploaded_at = excluded.uploaded_at;
end
$$;

revoke all on function public.store_photo_set(text, text) from public, anon;
grant execute on function public.store_photo_set(text, text) to authenticated, service_role;

-- ── 성수 본점 체크리스트 항목 ────────────────────────────────
-- 두 항목 모두 성수 전용, 매일. 이미지는 화면의 "인스타 스토리" 카드에서 받는다. 이미 있으면 다시 넣지 않는다.
insert into public.checklist_items (store, grp, content, sort_order)
select '성수', '인스타 스토리', v.content, v.sort_order
from (values
    ('신규 입고 스토리 올리기 (아래 "인스타 스토리" 카드의 오늘 이미지 받아서 업로드)', 300),
    ('정리 완료 스토리 올리기 (카드의 매장별 이미지를 매장당 한 장씩 업로드)', 310)
) as v(content, sort_order)
where not exists (
    select 1 from public.checklist_items i where i.store = '성수' and i.grp = '인스타 스토리' and i.content = v.content
);
