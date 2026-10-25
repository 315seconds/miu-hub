-- 담당자 기록을 로그인 계정 이름으로 고정 (이동 세션·스캔, 가격수정). 서버 작업(service_role)은 예외

create or replace function public.force_login_name() returns trigger language plpgsql set search_path = '' as $fn$
declare v_name text;
begin
  if current_user = 'authenticated' then
    select p.name into v_name from public.profiles p where p.id = auth.uid();
    if v_name is null or btrim(v_name) = '' then
      raise exception '계정에 이름이 설정돼 있지 않아요. 관리자에게 요청해 주세요.' using errcode = 'P0001';
    end if;
    new := jsonb_populate_record(new, jsonb_build_object(tg_argv[0], v_name));
  end if;
  return new;
end
$fn$;
drop trigger if exists force_login_name on public.move_sessions;
create trigger force_login_name before insert on public.move_sessions for each row execute function public.force_login_name('created_by');
drop trigger if exists force_login_name on public.session_items;
create trigger force_login_name before insert on public.session_items for each row execute function public.force_login_name('scanned_by');
drop trigger if exists force_login_name on public.price_changes;
create trigger force_login_name before insert on public.price_changes for each row execute function public.force_login_name('changed_by');
