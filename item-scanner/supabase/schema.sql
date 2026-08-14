-- item-scanner 스키마 (테스트 전용 Supabase 프로젝트에 적용)
--
-- 기존 barcode-photo-scanner(leehk2275)의 photo_targets(정적 목록) 방식을 버리고,
-- 스캔 시점에 브라우저가 운영 Supabase(inventory_items, 읽기전용 anon key)를 직접 조회해
-- brand_needed/photo_needed를 판정한 뒤 이 테스트 프로젝트에는 그 판정 결과와 캡처 결과만 기록한다.
-- 운영 DB에는 이 프로젝트에서 아무것도 쓰지 않는다 (읽기 전용 조회만).
--
-- 행거 단위 스캔 집계(scan_hangers/hanger_scans)와 기기별 원자적 첫 스캔 처리(record_hanger_scan RPC)는
-- leehk2275/barcode-photo-scanner에서 검증된 패턴을 그대로 재사용한다.

create schema if not exists private;

-- 행거 진행 상태 -------------------------------------------------------

create table if not exists public.scan_hangers (
  id bigint generated always as identity primary key,
  device_id uuid not null,
  hanger_number integer not null check (hanger_number > 0),
  status text not null default 'active'
    check (status in ('active', 'completed')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  completed_at_kst timestamp without time zone
    generated always as (completed_at at time zone 'Asia/Seoul') stored,
  constraint scan_hangers_device_number_key unique (device_id, hanger_number),
  constraint scan_hangers_id_device_key unique (id, device_id),
  constraint scan_hangers_completion_check check (
    (status = 'active' and completed_at is null)
    or (status = 'completed' and completed_at is not null)
  )
);

create unique index if not exists scan_hangers_one_active_per_device_idx
  on public.scan_hangers (device_id)
  where status = 'active';

create index if not exists scan_hangers_device_status_number_idx
  on public.scan_hangers (device_id, status, hanger_number desc);

-- 행거별 스캔 기록 -------------------------------------------------------
-- brand_needed/photo_needed: 스캔 시점에 운영 inventory_items를 조회해 판정한 값(브라우저가 전달).
-- brand_captured/photo_captured: 이 세션에서 실제로 입력/촬영해 저장했는지 여부.

create table if not exists public.hanger_scans (
  id bigint generated always as identity primary key,
  hanger_id bigint not null,
  device_id uuid not null,
  barcode text not null check (char_length(barcode) between 1 and 128),
  brand_needed boolean not null default false,
  photo_needed boolean not null default false,
  brand_captured boolean not null default false,
  photo_captured boolean not null default false,
  scanned_at timestamptz not null default now(),
  scanned_at_kst timestamp without time zone
    generated always as (scanned_at at time zone 'Asia/Seoul') stored,
  constraint hanger_scans_hanger_device_fkey
    foreign key (hanger_id, device_id)
    references public.scan_hangers(id, device_id)
    on delete cascade,
  constraint hanger_scans_device_barcode_key unique (device_id, barcode)
);

create index if not exists hanger_scans_device_hanger_id_idx
  on public.hanger_scans (device_id, hanger_id, id desc);

create index if not exists hanger_scans_hanger_device_idx
  on public.hanger_scans (hanger_id, device_id);

-- 캡처 결과 (브랜드 텍스트 / 사진 Storage 경로) --------------------------

create table if not exists public.item_captures (
  id bigint generated always as identity primary key,
  barcode text not null check (char_length(barcode) between 1 and 128),
  brand text,
  storage_path text,
  device_id uuid not null,
  hanger_scan_id bigint references public.hanger_scans(id) on delete set null,
  created_at timestamptz not null default now(),
  created_at_kst timestamp without time zone
    generated always as (created_at at time zone 'Asia/Seoul') stored,
  constraint item_captures_has_data check (brand is not null or storage_path is not null)
);

create index if not exists item_captures_hanger_scan_id_idx
  on public.item_captures (hanger_scan_id);
create index if not exists item_captures_device_id_idx
  on public.item_captures (device_id);
create index if not exists item_captures_barcode_idx
  on public.item_captures (barcode);

-- 바코드 정규화 트리거 ----------------------------------------------------

create or replace function private.normalize_hanger_scan_barcode()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.barcode := upper(regexp_replace(btrim(new.barcode), '\s+', '', 'g'));
  return new;
end;
$$;

revoke all on function private.normalize_hanger_scan_barcode() from public, anon, authenticated;

drop trigger if exists normalize_hanger_scan_barcode_before_write on public.hanger_scans;
create trigger normalize_hanger_scan_barcode_before_write
before insert or update of barcode on public.hanger_scans
for each row execute function private.normalize_hanger_scan_barcode();

-- 첫 스캔 시 행거 자동 생성 + 스캔 기록을 하나의 트랜잭션으로 원자 처리 ---
-- (leehk2275/barcode-photo-scanner의 v1.5.3 패턴 재사용: 기기별 advisory lock으로
--  여러 탭의 첫 스캔 동시 실행 시 행거 생성 경합 방지)

create or replace function private.record_hanger_scan(
  p_device_id uuid,
  p_barcode text,
  p_brand_needed boolean,
  p_photo_needed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_device_id text;
  normalized_barcode text;
  hanger_row public.scan_hangers%rowtype;
  scan_row public.hanger_scans%rowtype;
begin
  request_device_id :=
    (nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-device-id');

  if request_device_id is null or request_device_id <> p_device_id::text then
    raise exception using
      errcode = '42501',
      message = 'device header does not match the requested device';
  end if;

  normalized_barcode := upper(regexp_replace(btrim(p_barcode), '\s+', '', 'g'));
  if char_length(normalized_barcode) not between 1 and 128 then
    raise exception using
      errcode = '22023',
      message = 'barcode length must be between 1 and 128 characters';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_device_id::text, 0)
  );

  select h.*
    into hanger_row
  from public.scan_hangers h
  where h.device_id = p_device_id
    and h.status = 'active'
  order by h.hanger_number desc
  limit 1
  for update;

  if not found then
    insert into public.scan_hangers (device_id, hanger_number, status)
    select p_device_id, coalesce(max(h.hanger_number), 0) + 1, 'active'
    from public.scan_hangers h
    where h.device_id = p_device_id
    returning * into hanger_row;
  end if;

  insert into public.hanger_scans (
    hanger_id,
    device_id,
    barcode,
    brand_needed,
    photo_needed
  ) values (
    hanger_row.id,
    p_device_id,
    normalized_barcode,
    coalesce(p_brand_needed, false),
    coalesce(p_photo_needed, false)
  )
  returning * into scan_row;

  return jsonb_build_object(
    'id', scan_row.id,
    'barcode', scan_row.barcode,
    'brand_needed', scan_row.brand_needed,
    'photo_needed', scan_row.photo_needed,
    'brand_captured', scan_row.brand_captured,
    'photo_captured', scan_row.photo_captured,
    'scanned_at', scan_row.scanned_at,
    'hanger_id', hanger_row.id,
    'hanger_number', hanger_row.hanger_number,
    'hanger_status', hanger_row.status,
    'hanger_created_at', hanger_row.created_at
  );
end;
$$;

create or replace function public.record_hanger_scan(
  p_device_id uuid,
  p_barcode text,
  p_brand_needed boolean,
  p_photo_needed boolean
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.record_hanger_scan(p_device_id, p_barcode, p_brand_needed, p_photo_needed);
$$;

revoke all on function private.record_hanger_scan(uuid, text, boolean, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.record_hanger_scan(uuid, text, boolean, boolean)
  from public, anon, authenticated, service_role;

grant usage on schema private to anon;
grant execute on function private.record_hanger_scan(uuid, text, boolean, boolean) to anon;
grant execute on function public.record_hanger_scan(uuid, text, boolean, boolean) to anon;

comment on function public.record_hanger_scan(uuid, text, boolean, boolean) is
  'Atomically creates the active hanger when needed and records its barcode scan with client-computed brand/photo need flags.';

-- 캡처 완료 처리(브랜드 저장/사진 저장) 도 같은 방식으로 device 헤더를 검증하는 RPC로 처리 ---

create or replace function private.save_item_capture(
  p_device_id uuid,
  p_hanger_scan_id bigint,
  p_barcode text,
  p_brand text,
  p_storage_path text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_device_id text;
  normalized_barcode text;
  scan_row public.hanger_scans%rowtype;
  capture_row public.item_captures%rowtype;
begin
  request_device_id :=
    (nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-device-id');

  if request_device_id is null or request_device_id <> p_device_id::text then
    raise exception using
      errcode = '42501',
      message = 'device header does not match the requested device';
  end if;

  if p_brand is null and p_storage_path is null then
    raise exception using
      errcode = '22023',
      message = 'either brand or storage_path must be provided';
  end if;

  normalized_barcode := upper(regexp_replace(btrim(p_barcode), '\s+', '', 'g'));

  select s.*
    into scan_row
  from public.hanger_scans s
  where s.id = p_hanger_scan_id
    and s.device_id = p_device_id
  for update;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'hanger scan not found for this device';
  end if;

  -- 행거 초기화 후 같은 바코드를 다시 스캔/저장하는 경우, 이전 캡처는 덮어쓰기(최신 것만 유지)한다.
  delete from public.item_captures
  where device_id = p_device_id
    and barcode = normalized_barcode;

  insert into public.item_captures (barcode, brand, storage_path, device_id, hanger_scan_id)
  values (normalized_barcode, p_brand, p_storage_path, p_device_id, p_hanger_scan_id)
  returning * into capture_row;

  update public.hanger_scans
  set brand_captured = brand_captured or (p_brand is not null),
      photo_captured = photo_captured or (p_storage_path is not null)
  where id = p_hanger_scan_id
    and device_id = p_device_id
  returning * into scan_row;

  return jsonb_build_object(
    'capture_id', capture_row.id,
    'brand_captured', scan_row.brand_captured,
    'photo_captured', scan_row.photo_captured
  );
end;
$$;

create or replace function public.save_item_capture(
  p_device_id uuid,
  p_hanger_scan_id bigint,
  p_barcode text,
  p_brand text,
  p_storage_path text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.save_item_capture(p_device_id, p_hanger_scan_id, p_barcode, p_brand, p_storage_path);
$$;

revoke all on function private.save_item_capture(uuid, bigint, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.save_item_capture(uuid, bigint, text, text, text)
  from public, anon, authenticated, service_role;

grant execute on function private.save_item_capture(uuid, bigint, text, text, text) to anon;
grant execute on function public.save_item_capture(uuid, bigint, text, text, text) to anon;

comment on function public.save_item_capture(uuid, bigint, text, text, text) is
  'Records a brand/photo capture result and marks the owning hanger scan as captured, scoped to the requesting device.';

-- RLS ---------------------------------------------------------------------
-- 브라우저는 클라이언트 생성 기기 UUID(x-device-id 헤더)만으로 자기 기록에 접근한다.
-- INSERT/UPDATE는 위 두 RPC를 통해서만 이뤄지므로 테이블 직접 쓰기 권한은 주지 않는다.

alter table public.scan_hangers enable row level security;
alter table public.hanger_scans enable row level security;
alter table public.item_captures enable row level security;

drop policy if exists "device can read own hangers" on public.scan_hangers;
create policy "device can read own hangers"
  on public.scan_hangers for select to anon
  using (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  );

drop policy if exists "device can complete own hangers" on public.scan_hangers;
create policy "device can complete own hangers"
  on public.scan_hangers for update to anon
  using (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  )
  with check (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  );

drop policy if exists "device can delete own hangers" on public.scan_hangers;
create policy "device can delete own hangers"
  on public.scan_hangers for delete to anon
  using (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  );

drop policy if exists "device can read own hanger scans" on public.hanger_scans;
create policy "device can read own hanger scans"
  on public.hanger_scans for select to anon
  using (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  );

drop policy if exists "device can delete own hanger scans" on public.hanger_scans;
create policy "device can delete own hanger scans"
  on public.hanger_scans for delete to anon
  using (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  );

drop policy if exists "device can read own captures" on public.item_captures;
create policy "device can read own captures"
  on public.item_captures for select to anon
  using (
    device_id::text = ((select current_setting('request.headers', true))::jsonb ->> 'x-device-id')
  );

grant usage on schema public to anon;
grant select, delete on table public.scan_hangers to anon;
grant update (status, completed_at) on table public.scan_hangers to anon;
grant select, delete on table public.hanger_scans to anon;
grant select on table public.item_captures to anon;
-- insert는 scan_hangers/hanger_scans/item_captures 모두 RPC(security definer)를 통해서만 가능,
-- 브라우저가 테이블에 직접 insert/update 권한을 갖지 않도록 위 GRANT에서 의도적으로 제외함.
grant usage, select on sequence public.scan_hangers_id_seq to anon;
grant usage, select on sequence public.hanger_scans_id_seq to anon;
grant usage, select on sequence public.item_captures_id_seq to anon;

comment on table public.scan_hangers is
  '테스트 전용 행거 진행 상태, 기기별 클라이언트 UUID로 격리됨.';
comment on table public.hanger_scans is
  '행거 단위로 묶인 바코드 스캔 기록. brand_needed/photo_needed는 스캔 시점 운영 DB 실시간 조회 결과.';
comment on table public.item_captures is
  '현장에서 입력/촬영한 브랜드·사진 캡처 결과 (운영 DB로의 반영은 별도 동기화 스크립트가 처리).';

notify pgrst, 'reload schema';
