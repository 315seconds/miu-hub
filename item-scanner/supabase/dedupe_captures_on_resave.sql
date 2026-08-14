-- 행거 초기화 후 같은 바코드를 다시 스캔해서 브랜드/사진을 재저장하면
-- item_captures에 같은 바코드가 두 건(구/신) 남는 문제를 고친다.
-- 저장 시점에 같은 device_id+barcode의 기존 캡처를 지우고 최신 것만 남기도록 변경.
-- 이미 배포된 item-scanner 테스트 프로젝트의 SQL Editor에서 실행.

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

-- 이미 쌓인 중복 캡처 정리: 바코드+device당 가장 최근(id가 가장 큰) 캡처만 남긴다.
delete from public.item_captures c
using public.item_captures newer
where c.device_id = newer.device_id
  and c.barcode = newer.barcode
  and c.id < newer.id;

notify pgrst, 'reload schema';
