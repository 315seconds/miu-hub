-- 입고 승인: 서버에서 한 번에 처리(바코드 발급, 상품 갱신, 승인자 기록)

create or replace function public.approve_inventory_session(p_session_id uuid)
returns jsonb language plpgsql set search_path = '' as $fn$
declare
  v_sess public.inventory_sessions%rowtype;
  v_name text;
  v_unsubmitted int;
  v_total int;
  v_first text; v_last text; v_n int := 0;
  r record; bc text;
begin
  select p.name into v_name from public.profiles p where p.id = auth.uid();
  if v_name is null or btrim(v_name) = '' then
    raise exception '프로필 이름이 없어 승인할 수 없어요. 관리자에게 이름 설정을 요청하세요.' using errcode = 'P0001';
  end if;

  -- 승인은 한 번에 하나씩 처리해서 세션끼리 바코드 번호가 섞이지 않게 한다
  perform pg_advisory_xact_lock(hashtext('approve_inventory_session'));

  select * into v_sess from public.inventory_sessions where id = p_session_id for update;
  if not found then
    raise exception '입고 세션을 찾을 수 없어요.' using errcode = 'P0001';
  end if;
  if v_sess.status <> 'pending' then
    raise exception '이미 처리된 세션이에요. (상태: %)', v_sess.status using errcode = 'P0001';
  end if;

  select count(*) into v_unsubmitted from public.inventory_hangers h where h.session_id = p_session_id and h.submitted_at is null;
  if v_unsubmitted > 0 then
    raise exception '미제출 행거가 있어요. (% 개)', v_unsubmitted using errcode = 'P0001';
  end if;

  select count(*) into v_total from public.inventory_items i join public.inventory_hangers h on h.id = i.hanger_id where h.session_id = p_session_id;
  if v_total = 0 then
    raise exception '아이템이 없어요.' using errcode = 'P0001';
  end if;

  for r in
    select i.id from public.inventory_items i join public.inventory_hangers h on h.id = i.hanger_id
    where h.session_id = p_session_id
    order by h.created_at asc, coalesce(i.order_index, 0) asc, i.created_at asc
  loop
    bc := public.next_barcode(v_sess.location);
    update public.inventory_items set barcode = bc where id = r.id;
    v_n := v_n + 1;
    if v_first is null then v_first := bc; end if;
    v_last := bc;
  end loop;

  update public.inventory_sessions
     set status = 'approved',
         start_barcode_num = regexp_replace(v_first, '^[A-Z]+', ''),
         approved_by = v_name,
         approved_at = now()
   where id = p_session_id;

  return jsonb_build_object('first', v_first, 'last', v_last, 'count', v_n, 'approved_by', v_name);
end
$fn$;
revoke all on function public.approve_inventory_session(uuid) from public, anon;
grant execute on function public.approve_inventory_session(uuid) to authenticated;

create or replace function public.force_approver_name() returns trigger language plpgsql set search_path = '' as $fn$
declare v_name text;
begin
  if current_user = 'authenticated' and new.status = 'approved'
     and (old.status is distinct from 'approved' or new.approved_by is distinct from old.approved_by) then
    select p.name into v_name from public.profiles p where p.id = auth.uid();
    if v_name is null or btrim(v_name) = '' then
      raise exception '프로필 이름이 없어 승인할 수 없어요' using errcode = '42501';
    end if;
    new.approved_by := v_name;
  end if;
  return new;
end
$fn$;
drop trigger if exists force_approver_name on public.inventory_sessions;
create trigger force_approver_name before update on public.inventory_sessions for each row execute function public.force_approver_name();
