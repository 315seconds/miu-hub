-- 대량 이동 저장 원자화 + 승인 취소 보호 (라벨 출력·키오스크·엑셀 기록 후에는 취소 불가)

create or replace function public.create_bulk_move_session(p_from text, p_to text, p_name text, p_valid jsonb, p_errors jsonb)
returns jsonb language plpgsql set search_path = '' as $fn$
declare v_id uuid; n_valid int := 0; n_err int := 0;
begin
  if coalesce(btrim(p_from), '') = '' or coalesce(btrim(p_to), '') = '' then
    raise exception '출발지와 도착지를 선택해 주세요.' using errcode = 'P0001';
  end if;
  if p_from = p_to then
    raise exception '출발지와 도착지가 같아요.' using errcode = 'P0001';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception '담당자를 선택해 주세요.' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_valid) is distinct from 'array' or jsonb_array_length(p_valid) = 0 then
    raise exception '제출할 바코드가 없어요.' using errcode = 'P0001';
  end if;

  -- 세션과 항목을 한 번에 저장한다. 중간에 하나라도 실패하면 전부 취소되어 빈 세션이나 일부만 들어간 세션이 남지 않는다.
  insert into public.move_sessions (session_date, from_location, to_location, status, created_by)
  values ((now() at time zone 'Asia/Seoul')::date, p_from, p_to, 'pending', p_name)
  returning id into v_id;

  insert into public.session_items (session_id, barcode, product_name, category, price, current_location, scanned_by, is_submitted, is_error)
  select v_id, x->>'barcode', coalesce(x->>'product_name', ''), coalesce(x->>'category', ''), coalesce(x->>'price', ''), p_from, p_name, true, false
  from jsonb_array_elements(p_valid) as x;
  get diagnostics n_valid = row_count;

  if jsonb_typeof(p_errors) = 'array' and jsonb_array_length(p_errors) > 0 then
    insert into public.session_items (session_id, barcode, scanned_by, is_submitted, is_error, error_msg)
    select v_id, e #>> '{}', p_name, true, true, '공동판매 파일에 없는 바코드'
    from jsonb_array_elements(p_errors) as e;
    get diagnostics n_err = row_count;
  end if;

  return jsonb_build_object('session_id', v_id, 'valid', n_valid, 'errors', n_err);
end
$fn$;
revoke all on function public.create_bulk_move_session(text, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.create_bulk_move_session(text, text, text, jsonb, jsonb) to authenticated;

create or replace function public.guard_reopen_inventory_session() returns trigger language plpgsql set search_path = '' as $fn$
begin
  if old.status = 'approved' and new.status = 'pending' and current_user = 'authenticated' then
    if old.excel_updated then
      raise exception '이미 엑셀에 기록된 세션은 승인을 취소할 수 없어요.' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.inventory_hangers h where h.session_id = old.id and (h.printed_at is not null or h.kiosk_exported_at is not null)) then
      raise exception '라벨을 이미 출력했거나 키오스크 파일을 내려받은 세션은 승인을 취소할 수 없어요. 번호가 바뀌면 붙인 라벨과 어긋나요.' using errcode = 'P0001';
    end if;
  end if;
  return new;
end
$fn$;
drop trigger if exists guard_reopen_inventory_session on public.inventory_sessions;
create trigger guard_reopen_inventory_session before update on public.inventory_sessions for each row execute function public.guard_reopen_inventory_session();
