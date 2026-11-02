-- Phase 16: a company admin lists, adds and removes admins of the same company.
--   An admin is a company_members row with role 'company_admin' whose employee is active (public.admin_company_id() checks exactly that).
--   The role is read from the database on every call, so promotion and removal work at once, with no new sign-in.
--   public.admin_list_admins()          the admins of my company
--   public.admin_add_admin(uuid)        promote an existing active employee of my company
--   public.admin_remove_admin(uuid)     take the role away (the person stays an employee); never myself, never the last working admin
--   private.working_admin_count(uuid, uuid)   active admins of a company, leaving one person out
-- Changes of the admin role are serialized per company (advisory lock), so two admins cannot remove each other at the same time.
-- Rollback: 20261102190000_phase16_admins_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.admin_company_id()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regclass('public.company_members') is null then
    raise exception 'phase16: expected objects are missing (the base schema and the security fixes must be applied first)';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- helper
create or replace function private.working_admin_count(p_company uuid, p_except uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.company_members m
  join public.employees e on e.id = m.user_id and e.company_id = m.company_id and e.is_active
  join public.companies c on c.id = m.company_id and c.is_active
  where m.company_id = p_company
    and m.role = 'company_admin'
    and m.user_id is distinct from p_except
$$;
revoke all on function private.working_admin_count(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- list
create or replace function public.admin_list_admins()
returns table (id uuid, full_name text, employee_number text, email text, is_active boolean, is_me boolean, since timestamp with time zone)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_me uuid := (select auth.uid());
begin
  return query
  select e.id, e.full_name, e.employee_number, u.email::text, e.is_active, e.id = v_me,
         coalesce(p.promoted_at, m.created_at)
  from public.company_members m
  join public.employees e on e.id = m.user_id and e.company_id = v_company
  join auth.users u on u.id = e.id
  left join (
    select l.target_id, max(l.created_at) as promoted_at
    from public.audit_log l
    where l.company_id = v_company and l.action = 'admin.added'
    group by l.target_id
  ) p on p.target_id = e.id::text
  where m.company_id = v_company and m.role = 'company_admin'
  order by 7, 2;
end;
$$;
revoke all on function public.admin_list_admins() from public, anon;
grant execute on function public.admin_list_admins() to authenticated;

-- ---------------------------------------------------------------- add
create or replace function public.admin_add_admin(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_emp record;
begin
  select e.full_name, e.employee_number, e.is_active, m.role
    into v_emp
  from public.employees e
  join public.company_members m on m.user_id = e.id and m.company_id = e.company_id
  where e.id = p_employee_id and e.company_id = v_company
  for update of m;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v_emp.role = 'company_admin' then
    raise exception 'already_admin' using errcode = 'P0001';
  end if;
  if not v_emp.is_active then
    raise exception 'employee_inactive' using errcode = 'P0001';
  end if;

  update public.company_members set role = 'company_admin'
  where user_id = p_employee_id and company_id = v_company;

  perform public.audit_write(v_company, 'admin.added', 'employee', p_employee_id::text,
    jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name));
  return jsonb_build_object('employee_id', p_employee_id, 'full_name', v_emp.full_name, 'employee_number', v_emp.employee_number);
end;
$$;
revoke all on function public.admin_add_admin(uuid) from public, anon;
grant execute on function public.admin_add_admin(uuid) to authenticated;

-- ---------------------------------------------------------------- remove
create or replace function public.admin_remove_admin(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_emp record;
begin
  -- One change of admins at a time per company. Two admins removing each other at the same moment would otherwise both pass
  -- the checks below and leave the company with nobody who can sign in to the panel.
  perform pg_advisory_xact_lock(hashtextextended('waqti.admins:' || v_company::text, 0));
  -- The caller may have lost the role while this call was waiting for the lock.
  if public.admin_company_id() is distinct from v_company then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select e.full_name, e.employee_number, m.role
    into v_emp
  from public.employees e
  join public.company_members m on m.user_id = e.id and m.company_id = e.company_id
  where e.id = p_employee_id and e.company_id = v_company
  for update of m;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if p_employee_id = (select auth.uid()) then
    raise exception 'cannot_remove_self' using errcode = 'P0001';
  end if;
  if v_emp.role <> 'company_admin' then
    raise exception 'not_admin' using errcode = 'P0001';
  end if;
  if private.working_admin_count(v_company, p_employee_id) < 1 then
    raise exception 'last_admin' using errcode = 'P0001';
  end if;

  update public.company_members set role = 'employee'
  where user_id = p_employee_id and company_id = v_company;

  perform public.audit_write(v_company, 'admin.removed', 'employee', p_employee_id::text,
    jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name));
  return jsonb_build_object('employee_id', p_employee_id, 'full_name', v_emp.full_name, 'employee_number', v_emp.employee_number);
end;
$$;
revoke all on function public.admin_remove_admin(uuid) from public, anon;
grant execute on function public.admin_remove_admin(uuid) to authenticated;
