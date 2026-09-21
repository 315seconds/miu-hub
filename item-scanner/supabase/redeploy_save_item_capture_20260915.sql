-- save_item_capture 함수 재배포 (2026-09-15)
-- 목적: photo_url 리터럴에 개행/공백이 섞여 저장되는 문제 원천 차단.
-- 사용: Supabase 대시보드 → SQL Editor → 이 파일 전체 복사·붙여넣기 → Run.
-- 주의: 함수 본문의 URL 리터럴은 반드시 한 줄로 유지할 것. 개행이 들어가면 재발.

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
  photo_url_base constant text := 'https://yqnocnzjrcsrwrvsvsyg.supabase.co/storage/v1/object/public/item-photos/';
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

  update public.inventory_items
  set
    brand     = case when p_brand is not null and (brand is null or brand = '')
                     then p_brand else brand end,
    photo_url = case when p_storage_path is not null and (photo_url is null or photo_url = '')
                     then photo_url_base || p_storage_path
                     else photo_url end
  where barcode = normalized_barcode
    and (
      (p_brand is not null and (brand is null or brand = ''))
      or (p_storage_path is not null and (photo_url is null or photo_url = ''))
    );

  return jsonb_build_object(
    'capture_id', capture_row.id,
    'brand_captured', scan_row.brand_captured,
    'photo_captured', scan_row.photo_captured
  );
end;
$$;

-- 검증: 배포된 함수 소스에 개행/공백 오염이 없는지 확인.
-- 아래 쿼리 결과가 반드시 0이어야 함.
select count(*) as corrupted_source_count
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'private'
  and p.proname = 'save_item_capture'
  and p.prosrc ~ 'supabas[[:space:]]';
