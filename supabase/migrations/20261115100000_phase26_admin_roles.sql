-- Phase 26: admin levels inside a company.
--   Today a company has two kinds of people on the admin side: the owner (company_members.role = 'company_admin', full access, unchanged)
--   and ordinary employees. This phase adds three limited levels, kept in the same column so there is one source of truth:
--     hr_admin     employees + everything a supervisor does
--     supervisor   requests, reviews and leave decisions + everything a viewer sees
--     viewer       read only (no salary, no payroll, no admin list)
--   Rules:
--   * Default deny. A limited level reaches only the admin functions listed for it in private.admin_role_rpcs (one row per role and function,
--     already flattened, so a new function is opened to one role with one insert and no code change). A new admin_* function is owner-only until listed.
--   * public.require_company_admin() is the single gate of every admin_* function. The owner path is unchanged. A limited level passes only when
--     the outermost admin_* function on the call stack is listed for his level. No admin_* frame on the stack (called straight, from a trigger,
--     from SQL) = closed, so the check fails closed.
--   * public.admin_company_id() stays owner-only. No table policy uses it, so a limited level gets no direct table access either.
--   * A limited level cannot touch an account that holds any admin level (private.assert_not_admin_target): 12 employee-targeting functions
--     get one extra line at the start of the body; for an owner it returns at once, so nothing changes for him.
--   * Admin levels never sign in with the phone alone (service_login_context: password required for every level, like the owner).
--   * Deleting an account that holds an admin level is refused until the level is taken away (admin_delete_employee, like the owner rule).
--   New: public.admin_list_admin_roles(), public.admin_set_admin_role(uuid, text) (owner only, audited, one change at a time per company).
--   my_admin_context() gets three more keys: admin_role, is_panel_user, permissions (null for the owner = everything).
--   Not changed on purpose: the "hr" approver step and its notifications stay with owners (a supervisor decides through admin_decide_request);
--   the create-employee / reset-employee-password edge functions stay owner-only (they need a deploy to change).
-- Rollback: 20261115100000_phase26_admin_roles_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.admin_company_id()') is null
     or to_regprocedure('public.my_admin_context()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regprocedure('private.working_admin_count(uuid, uuid)') is null
     or to_regprocedure('public.service_login_context(text)') is null
     or to_regprocedure('public.admin_delete_employee(uuid, text)') is null
     or to_regclass('public.company_members') is null then
    raise exception 'phase26: expected objects are missing (phases 16 and 21 must be applied first)';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- the role values
alter table public.company_members drop constraint if exists company_members_role_check;
alter table public.company_members add constraint company_members_role_check
  check (role in ('company_admin', 'hr_admin', 'supervisor', 'viewer', 'employee'));

-- ---------------------------------------------------------------- who may call what (data, private)
create table if not exists private.admin_role_rpcs (
  role text not null check (role in ('hr_admin', 'supervisor', 'viewer')),
  rpc  text not null,
  primary key (role, rpc)
);
revoke all on table private.admin_role_rpcs from public, anon, authenticated;

-- viewer: read only. Supervisor = viewer + decisions. HR admin = supervisor + employee administration. Everything else is owner-only.
insert into private.admin_role_rpcs (role, rpc)
select r.role, f.rpc
from (values
  ('viewer', 'admin_list_requests'), ('viewer', 'admin_list_employees'), ('viewer', 'admin_list_attendance'),
  ('viewer', 'admin_list_missing_checkins'), ('viewer', 'admin_list_overtime'), ('viewer', 'admin_list_leave_days'),
  ('viewer', 'admin_list_leave_day_cancellations'), ('viewer', 'admin_list_holidays'), ('viewer', 'admin_list_work_locations'),
  ('viewer', 'admin_list_permission_types'), ('viewer', 'admin_list_custom_kinds'), ('viewer', 'admin_list_employee_managers'),
  ('viewer', 'admin_get_company_settings'), ('viewer', 'admin_get_punch_settings'), ('viewer', 'admin_get_grace_settings'),
  ('viewer', 'admin_get_holiday_settings'), ('viewer', 'admin_get_leave_policy'), ('viewer', 'admin_get_leave_window'),
  ('viewer', 'admin_get_overtime_settings'), ('viewer', 'admin_get_approval_chains'), ('viewer', 'admin_get_profile_visibility'),
  ('viewer', 'admin_get_auto_punch_mode'), ('viewer', 'admin_punch_mode_preview'),
  ('supervisor', 'admin_review_queue'), ('supervisor', 'admin_decide_request'), ('supervisor', 'admin_decide_leave_day'),
  ('supervisor', 'admin_resolve_leave_conflict'), ('supervisor', 'admin_resolve_review'),
  ('supervisor', 'admin_dismiss_missing_checkin'), ('supervisor', 'admin_get_leave_years'),
  ('supervisor', 'admin_get_employee_kind_days'), ('supervisor', 'admin_get_employee_grace'),
  ('hr_admin', 'admin_get_employee_profile'), ('hr_admin', 'admin_save_employee_profile'), ('hr_admin', 'admin_update_employee'),
  ('hr_admin', 'admin_add_punch'), ('hr_admin', 'admin_remove_device'), ('hr_admin', 'admin_list_device_bindings'),
  ('hr_admin', 'admin_set_employee_manager'), ('hr_admin', 'admin_set_employee_grace'), ('hr_admin', 'admin_set_employee_kind_days'),
  ('hr_admin', 'admin_set_employee_location_policy'), ('hr_admin', 'admin_set_employee_punch_windows'),
  ('hr_admin', 'admin_set_geofence'), ('hr_admin', 'admin_use_location_geofence'), ('hr_admin', 'admin_set_leave_year')
) as f(lvl, rpc)
join (values ('viewer', 1), ('supervisor', 2), ('hr_admin', 3)) as r(role, rank) on true
join (values ('viewer', 1), ('supervisor', 2), ('hr_admin', 3)) as fl(lvl, rank) on fl.lvl = f.lvl and fl.rank <= r.rank
on conflict do nothing;

-- ---------------------------------------------------------------- helpers (private)
-- The signed-in user's limited level, when he has one and he and his company are active (same conditions as public.admin_company_id()).
create or replace function private.limited_admin()
returns table (company_id uuid, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.company_id, m.role
  from public.company_members m
  join public.companies c on c.id = m.company_id and c.is_active
  join public.employees e on e.id = m.user_id and e.is_active
  where m.user_id = (select auth.uid()) and m.role in ('hr_admin', 'supervisor', 'viewer')
$$;
revoke all on function private.limited_admin() from public, anon, authenticated;

-- A limited level never changes an account that holds an admin level (in his own company). Owners are not restricted (returns at once).
create or replace function private.assert_not_admin_target(p_employee_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if public.admin_company_id() is not null then
    return;
  end if;
  if exists (
    select 1
    from public.company_members t
    join public.company_members me on me.company_id = t.company_id and me.user_id = (select auth.uid())
    where t.user_id = p_employee_id and t.role <> 'employee'
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
end;
$$;
revoke all on function private.assert_not_admin_target(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- the gate of every admin_* function
create or replace function public.require_company_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.admin_company_id();
  v_role text;
  v_ctx text;
  v_rpc text;
begin
  if v_company is null then
    -- Not an owner. A limited level passes only inside an admin function that is listed for his level.
    select l.company_id, l.role into v_company, v_role from private.limited_admin() l;
    if v_company is null then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    -- The function the client called is the OUTERMOST admin_* frame of the call stack (the last one in the text).
    -- Functions with a fixed search_path are printed with their schema, the others without it.
    get diagnostics v_ctx = pg_context;
    select t.m[1] into v_rpc
    from regexp_matches(v_ctx, 'PL/pgSQL function (?:public\.)?(admin_[a-z0-9_]+)\(', 'g') with ordinality as t(m, n)
    order by t.n desc
    limit 1;
    if v_rpc is null or not exists (select 1 from private.admin_role_rpcs r where r.role = v_role and r.rpc = v_rpc) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;
  -- A temporary password (shown to whoever created the account) must be replaced first.
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) then
    raise exception 'must_change_password' using errcode = '42501';
  end if;
  return v_company;
end;
$$;

-- ---------------------------------------------------------------- the context of the signed-in user (three keys added)
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
    'is_platform_admin', public.is_platform_admin(),
    -- phase 26. admin_role: the level that works now (null = none). permissions: the admin functions of a limited level (null for the owner = all).
    'admin_role', case when public.admin_company_id() is not null then 'company_admin' else (select l.role from private.limited_admin() l) end,
    'is_panel_user', public.admin_company_id() is not null or exists (select 1 from private.limited_admin()),
    'permissions', case when public.admin_company_id() is not null then null
                        else (select jsonb_agg(r.rpc order by r.rpc) from private.admin_role_rpcs r
                              join private.limited_admin() l on l.role = r.role) end
  )
  from (select 1) one
  left join public.company_members m on m.user_id = (select auth.uid())
  left join public.companies c on c.id = m.company_id
$$;

-- ---------------------------------------------------------------- list and set the levels (owner only: in no list above)
create or replace function public.admin_list_admin_roles()
returns table (id uuid, full_name text, employee_number text, email text, is_active boolean, is_me boolean, role text, since timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_me uuid := (select auth.uid());
begin
  return query
  select e.id, e.full_name, e.employee_number, u.email::text, e.is_active, e.id = v_me, m.role,
         coalesce(p.changed_at, m.created_at)
  from public.company_members m
  join public.employees e on e.id = m.user_id and e.company_id = v_company
  join auth.users u on u.id = e.id
  left join (
    select l.target_id, max(l.created_at) as changed_at
    from public.audit_log l
    where l.company_id = v_company and l.action in ('admin.added', 'admin.role_changed')
    group by l.target_id
  ) p on p.target_id = e.id::text
  where m.company_id = v_company and m.role <> 'employee'
  order by case m.role when 'company_admin' then 0 when 'hr_admin' then 1 when 'supervisor' then 2 else 3 end, 8, 2;
end;
$$;
revoke all on function public.admin_list_admin_roles() from public, anon;
grant execute on function public.admin_list_admin_roles() to authenticated;

create or replace function public.admin_set_admin_role(p_employee_id uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_emp record;
begin
  if p_role is null or p_role not in ('company_admin', 'hr_admin', 'supervisor', 'viewer', 'employee') then
    raise exception 'invalid_role' using errcode = 'P0001';
  end if;
  -- One change of admin levels at a time per company (the same lock as phase 16), so two owners cannot demote each other at the same moment.
  perform pg_advisory_xact_lock(hashtextextended('waqti.admins:' || v_company::text, 0));
  -- The caller may have lost the role while this call was waiting for the lock.
  if public.admin_company_id() is distinct from v_company then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_employee_id = (select auth.uid()) then
    raise exception 'cannot_change_self' using errcode = 'P0001';
  end if;

  select e.full_name, e.employee_number, e.is_active, m.role
    into v_emp
  from public.employees e
  join public.company_members m on m.user_id = e.id and m.company_id = e.company_id
  where e.id = p_employee_id and e.company_id = v_company
  for update of m;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v_emp.role = p_role then
    raise exception 'no_change' using errcode = 'P0001';
  end if;
  if p_role <> 'employee' and not v_emp.is_active then
    raise exception 'employee_inactive' using errcode = 'P0001';
  end if;
  if v_emp.role = 'company_admin' and private.working_admin_count(v_company, p_employee_id) < 1 then
    raise exception 'last_admin' using errcode = 'P0001';
  end if;

  update public.company_members set role = p_role
  where user_id = p_employee_id and company_id = v_company;

  perform public.audit_write(v_company, 'admin.role_changed', 'employee', p_employee_id::text,
    jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name, 'from', v_emp.role, 'to', p_role));
  -- Keep the phase 16 records true for owners (its list shows "since" from admin.added).
  if p_role = 'company_admin' then
    perform public.audit_write(v_company, 'admin.added', 'employee', p_employee_id::text,
      jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name));
  elsif v_emp.role = 'company_admin' then
    perform public.audit_write(v_company, 'admin.removed', 'employee', p_employee_id::text,
      jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name));
  end if;
  return jsonb_build_object('employee_id', p_employee_id, 'full_name', v_emp.full_name, 'employee_number', v_emp.employee_number,
                            'role', p_role, 'previous', v_emp.role);
end;
$$;
revoke all on function public.admin_set_admin_role(uuid, text) from public, anon;
grant execute on function public.admin_set_admin_role(uuid, text) to authenticated;

-- ---------------------------------------------------------------- the existing functions that get one extra line
-- Each body starts with the check "a limited level may not touch an account that holds an admin level". The text of every function is read
-- from the database and one line is added after the first line that is only "begin"; the run stops (and nothing is kept) when a function
-- does not have exactly one such line. CREATE OR REPLACE keeps the grants.
do $patch$
declare
  v_sig text;
  v_def text;
  v_marker constant text := E'\nbegin\n';
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
      continue;
    end if;
    if (length(v_def) - length(replace(v_def, v_marker, ''))) <> length(v_marker) then
      raise exception 'phase26: % does not have exactly one body start', v_sig;
    end if;
    execute replace(v_def, v_marker, v_marker || E'  perform private.assert_not_admin_target(p_employee_id);\n');
  end loop;
end
$patch$;

-- A phone alone never signs in an admin of any level (phase 9 rule, was: only the owner).
do $patch$
declare
  v_def text := pg_get_functiondef('public.service_login_context(text)'::regprocedure);
  v_old constant text := 'm.role = ''company_admin''';
begin
  if position('m.role <> ''employee''' in v_def) > 0 then
    return;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) <> length(v_old) then
    raise exception 'phase26: service_login_context does not contain the admin check exactly once';
  end if;
  execute replace(v_def, v_old, 'm.role <> ''employee''');
end
$patch$;

-- An account that holds any admin level cannot be deleted before the level is taken away (phase 21 rule, was: only the owner).
do $patch$
declare
  v_def text := pg_get_functiondef('public.admin_delete_employee(uuid, text)'::regprocedure);
  v_old constant text := 'if v_role = ''company_admin'' then';
begin
  if position('if v_role in (''company_admin'', ''hr_admin'', ''supervisor'', ''viewer'') then' in v_def) > 0 then
    return;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) <> length(v_old) then
    raise exception 'phase26: admin_delete_employee does not contain the admin check exactly once';
  end if;
  execute replace(v_def, v_old, 'if v_role in (''company_admin'', ''hr_admin'', ''supervisor'', ''viewer'') then');
end
$patch$;
