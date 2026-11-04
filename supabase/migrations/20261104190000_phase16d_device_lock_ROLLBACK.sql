-- Rollback of phase 16d: no phone binding. require_active_employee and admin_remove_device as before (baseline / phase 8b).
drop function if exists public.admin_list_device_bindings();
drop function if exists public.employee_bind_device(text, text);
CREATE OR REPLACE FUNCTION public.require_active_employee()
 RETURNS TABLE(employee_id uuid, company_id uuid, location_policy text, outside_action text, max_accuracy_m numeric, timezone text, full_name text, employee_number text, company_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) then
    raise exception 'must_change_password' using errcode = '42501';
  end if;
  return query
  select e.id, e.company_id, e.location_policy, coalesce(e.outside_action, c.default_outside_action),
         c.max_accuracy_m, c.timezone, e.full_name, e.employee_number, c.name
  from public.employees e
  join public.companies c on c.id = e.company_id
  where e.id = v_uid and e.is_active and c.is_active;
  if not found then
    raise exception 'employee_inactive' using errcode = '42501';
  end if;
end;
$function$
;
revoke all on function public.require_active_employee() from public, anon, authenticated;
grant execute on function public.require_active_employee() to service_role;
create or replace function public.admin_remove_device(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_label text;
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  delete from public.webauthn_credentials where employee_id = p_employee_id and company_id = v_company
  returning device_label into v_label;
  delete from private.punch_tickets where employee_id = p_employee_id;
  if found or v_label is not null then
    perform public.audit_write(v_company, 'device.remove', 'employee', p_employee_id::text, jsonb_build_object('device_label', v_label));
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_remove_device(uuid) from public, anon;
grant execute on function public.admin_remove_device(uuid) to authenticated;
drop table if exists private.device_unbinds;
drop table if exists private.device_sessions;
drop table if exists public.employee_devices;
alter table public.companies drop column if exists device_lock;
