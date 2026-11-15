-- Rollback of phase 26 (admin levels). Anyone who holds a limited level becomes an ordinary employee again; owners are not touched.
-- Run it in one transaction (psql -1).

-- 1) the extra lines in the existing functions
do $unpatch$
declare
  v_sig text;
  v_def text;
begin
  foreach v_sig in array array[
    'public.admin_update_employee(uuid, text, text, boolean, boolean)',
    'public.admin_save_employee_profile(uuid, text, text, text, text, text, date, date, uuid, boolean, boolean, numeric, jsonb, jsonb, jsonb)',
    'public.admin_remove_device(uuid)',
    'public.admin_add_punch(uuid, text, timestamp with time zone, text)',
    'public.admin_set_employee_manager(uuid, uuid)',
    'public.admin_set_employee_grace(uuid, integer, integer)',
    'public.admin_set_employee_kind_days(uuid, jsonb)',
    'public.admin_set_employee_location_policy(uuid, text, text)',
    'public.admin_set_employee_punch_windows(uuid, integer, integer, integer, integer)',
    'public.admin_set_geofence(uuid, text, double precision, double precision, numeric)',
    'public.admin_use_location_geofence(uuid)',
    'public.admin_set_leave_year(uuid, integer, numeric, numeric, numeric)'
  ] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if position('private.assert_not_admin_target' in v_def) > 0 then
      execute replace(v_def, E'  perform private.assert_not_admin_target(p_employee_id);\n', '');
    end if;
  end loop;

  v_def := pg_get_functiondef('public.service_login_context(text)'::regprocedure);
  if position('m.role <> ''employee''' in v_def) > 0 then
    execute replace(v_def, 'm.role <> ''employee''', 'm.role = ''company_admin''');
  end if;

  v_def := pg_get_functiondef('public.admin_delete_employee(uuid, text)'::regprocedure);
  if position('if v_role in (''company_admin'', ''hr_admin'', ''supervisor'', ''viewer'') then' in v_def) > 0 then
    execute replace(v_def, 'if v_role in (''company_admin'', ''hr_admin'', ''supervisor'', ''viewer'') then', 'if v_role = ''company_admin'' then');
  end if;
end
$unpatch$;

-- 2) the gate and the context, as they were before
create or replace function public.require_company_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.admin_company_id();
begin
  if v_company is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- A temporary password (shown to whoever created the account) must be replaced first.
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) then
    raise exception 'must_change_password' using errcode = '42501';
  end if;
  return v_company;
end;
$$;

create or replace function public.my_admin_context()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', (select auth.uid()),
    'company_id', m.company_id,
    'company_name', c.name,
    'company_role', m.role,
    'is_company_admin', public.admin_company_id() is not null,
    'is_platform_admin', public.is_platform_admin()
  )
  from (select 1) one
  left join public.company_members m on m.user_id = (select auth.uid())
  left join public.companies c on c.id = m.company_id
$$;

-- 3) the new functions, helpers and data
drop function if exists public.admin_set_admin_role(uuid, text);
drop function if exists public.admin_list_admin_roles();
drop function if exists private.assert_not_admin_target(uuid);
drop function if exists private.limited_admin();
drop table if exists private.admin_role_rpcs;

-- 4) the levels go back to ordinary employees, then the old constraint
update public.company_members set role = 'employee' where role in ('hr_admin', 'supervisor', 'viewer');
alter table public.company_members drop constraint if exists company_members_role_check;
alter table public.company_members add constraint company_members_role_check check (role in ('company_admin', 'employee'));
