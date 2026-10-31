-- ============================================================================
-- Waqti Phase 4b: the admin panel needs to SEE who manages whom (phase 4 only let it SET it).
-- Read-only. Company admins only, own company only.
-- ============================================================================

do $guard$
begin
  if to_regclass('public.approval_steps') is null then
    raise exception 'phase 4 must be applied first';
  end if;
end
$guard$;

-- {"<employee id>": "<manager id>", ...} for the employees of my company that have a manager.
create or replace function public.admin_list_employee_managers()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return coalesce((
    select jsonb_object_agg(e.id, e.manager_id)
    from public.employees e
    where e.company_id = v_company and e.manager_id is not null), '{}'::jsonb);
end;
$$;

revoke execute on function public.admin_list_employee_managers() from public, anon;
grant execute on function public.admin_list_employee_managers() to authenticated;
