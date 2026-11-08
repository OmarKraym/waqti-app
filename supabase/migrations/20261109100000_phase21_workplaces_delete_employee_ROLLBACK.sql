-- Rollback of phase 21 (20261109100000_phase21_workplaces_delete_employee.sql).
-- Removes the two delete functions and the guard trigger, and restores the four functions it replaced to their earlier bodies
-- (admin_list_employees, admin_list_work_locations, admin_add_work_location, platform_list_companies) and the old unique index.
-- It KEEPS the two deleted_at columns and the check constraint: they are the record of what was deleted and when, nothing is
-- erased here. The places that were deleted get a suffix in their name (a deleted place and a live one may share a name, which the
-- old index would not allow), so after a rollback they show in the lists again, marked as deleted. Employees that were deleted stay
-- inactive. To remove the columns for good, after checking nothing needs them:
--   alter table public.employees drop constraint employees_deleted_inactive_chk;
--   alter table public.employees drop column deleted_at;  alter table public.work_locations drop column deleted_at;

drop function if exists public.admin_delete_employee(uuid, text);
drop function if exists public.admin_delete_work_location(uuid, uuid);
drop trigger if exists employees_guard_deleted_location on public.employees;
drop function if exists private.guard_deleted_location();

-- the old index cannot hold a deleted and a live place with the same name: mark the deleted ones
update public.work_locations
   set name = left(name, 70) || ' (محذوف ' || to_char(deleted_at at time zone 'UTC', 'YYYY-MM-DD') || ' ' || left(id::text, 8) || ')'
 where deleted_at is not null and name not like '% (محذوف %)';
drop index if exists public.work_locations_name_uidx;
create unique index work_locations_name_uidx on public.work_locations (company_id, lower(btrim(name)));

CREATE OR REPLACE FUNCTION public.admin_add_work_location(p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
begin
  if length(v_name) not between 1 and 100 then
    raise exception 'invalid_location_name' using errcode = '22023';
  end if;

  insert into public.work_locations (company_id, name) values (v_company, v_name)
  on conflict (company_id, (lower(btrim(name)))) do nothing
  returning id into v_id;

  if v_id is null then
    select w.id into v_id from public.work_locations w
    where w.company_id = v_company and lower(btrim(w.name)) = lower(v_name);
  else
    perform public.audit_write(v_company, 'work_location.add', 'work_location', v_id::text, jsonb_build_object('name', v_name));
  end if;
  return v_id;
end;
$function$;
revoke all on function public.admin_add_work_location(text) from public, anon;
grant execute on function public.admin_add_work_location(text) to authenticated;

CREATE OR REPLACE FUNCTION public.admin_list_employees()
 RETURNS TABLE(id uuid, email text, full_name text, employee_number text, department text, is_active boolean, geofence_required boolean, created_at timestamp with time zone, geofence_id uuid, geofence_name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric, job_title text, gender text, birth_date date, hire_date date, work_location_id uuid, work_location_name text, geofence_inherited boolean, location_policy text, outside_action text, has_device boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    e.id, u.email::text, e.full_name, e.employee_number, e.department, e.is_active,
    e.geofence_required, e.created_at, g.id, g.name,
    extensions.st_y(g.center::extensions.geometry), extensions.st_x(g.center::extensions.geometry), g.radius_meters,
    e.job_title, e.gender, e.birth_date, e.hire_date, e.work_location_id,
    wl.name, (g.source_location_id is not null),
    e.location_policy, e.outside_action,
    exists (select 1 from public.webauthn_credentials wc where wc.employee_id = e.id)
  from public.employees e
  join auth.users u on u.id = e.id
  left join public.work_locations wl on wl.id = e.work_location_id and wl.company_id = v_company
  left join lateral (
    select x.* from public.employee_geofences x
    where x.employee_id = e.id and x.company_id = v_company and x.is_active
      and x.valid_from <= now() and (x.valid_until is null or x.valid_until > now())
    order by x.created_at desc limit 1
  ) g on true
  where e.company_id = v_company
  order by e.created_at desc;
end;
$function$;
revoke all on function public.admin_list_employees() from public, anon;
grant execute on function public.admin_list_employees() to authenticated;

drop function if exists public.admin_list_work_locations();
CREATE FUNCTION public.admin_list_work_locations()
 RETURNS TABLE(id uuid, name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric, employees_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    w.id, w.name,
    extensions.st_y(w.geofence_center::extensions.geometry), extensions.st_x(w.geofence_center::extensions.geometry),
    w.geofence_radius_meters,
    (select count(*) from public.employees e where e.work_location_id = w.id and e.company_id = v_company)
  from public.work_locations w
  where w.company_id = v_company
  order by w.name;
end;
$function$;
revoke all on function public.admin_list_work_locations() from public, anon;
grant execute on function public.admin_list_work_locations() to authenticated;

create or replace function public.platform_list_companies()
returns table(id uuid, name text, timezone text, is_active boolean, employees_count bigint, admins_count bigint, created_at timestamp with time zone)
language plpgsql
stable security definer
set search_path to 'public'
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select c.id, c.name, c.timezone, c.is_active,
         (select count(*) from public.employees e where e.company_id = c.id),
         (select count(*) from public.company_members m where m.company_id = c.id and m.role = 'company_admin'),
         c.created_at
  from public.companies c
  order by c.created_at;
end;
$$;
revoke all on function public.platform_list_companies() from public, anon;
grant execute on function public.platform_list_companies() to authenticated;
