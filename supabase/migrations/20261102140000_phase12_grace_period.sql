-- Phase 12: grace period (فترة السماح) for late arrival and early leave.
--   * companies.late_grace_min / early_grace_min = company default (minutes, 0 = no grace)
--   * employees.late_grace_min / early_grace_min = this employee's own value (null = use the company value)
--   * Definition (shift = that employee's scheduled shift on that local day):
--       late   = the FIRST check-in of the day is after shift start. Within the grace: 0. Beyond it: ALL the minutes
--                since the shift start count (the grace excuses a short delay, it is not a free allowance).
--       early  = the LAST check-out of the day is before shift end, same rule with the early grace.
--       No scheduled shift that day (day off) = nothing is late or early.
--   * The attendance list (admin_list_attendance) gets two new columns: late_minutes, early_minutes
--     (null = not applicable, 0 = within the grace / on time).
-- Nothing is blocked or rejected: this only MARKS. Punch windows and requests are not touched.
-- Rollback: 20261102140000_phase12_grace_period_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('private.shift_bounds(uuid, date, text)') is null
     or to_regprocedure('public.require_company_admin()') is null then
    raise exception 'phase12: expected functions are missing';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'admin_list_attendance'
                   and pg_get_function_result(p.oid) like '%missed_checkout boolean%') then
    raise exception 'phase12: run phase 8b first (admin_list_attendance)';
  end if;
end
$guard$;

alter table public.companies
  add column late_grace_min smallint not null default 0 check (late_grace_min between 0 and 240),
  add column early_grace_min smallint not null default 0 check (early_grace_min between 0 and 240);
alter table public.employees
  add column late_grace_min smallint check (late_grace_min between 0 and 240),
  add column early_grace_min smallint check (early_grace_min between 0 and 240);

-- Minutes late (check-in) or early (check-out) of one punch, or null when it does not apply.
create or replace function private.punch_lateness(p_employee uuid, p_event uuid, p_type text, p_at timestamptz)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_day date;
  v_start timestamptz;
  v_end timestamptz;
  v_grace integer;
  v_min integer;
begin
  select c.timezone, case p_type when 'check_in' then coalesce(e.late_grace_min, c.late_grace_min)
                                 else coalesce(e.early_grace_min, c.early_grace_min) end
    into v_tz, v_grace
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = p_employee;
  if v_tz is null then return null; end if;
  v_day := (p_at at time zone v_tz)::date;
  select s.shift_start, s.shift_end into v_start, v_end from private.shift_bounds(p_employee, v_day, v_tz) s;
  if v_start is null or v_end <= v_start then return null; end if;   -- day off, or a shift that crosses midnight

  if p_type = 'check_in' then
    if exists (select 1 from public.attendance_events x
               where x.employee_id = p_employee and x.event_type = 'check_in'
                 and (x.occurred_at at time zone v_tz)::date = v_day
                 and (x.occurred_at, x.id) < (p_at, p_event)) then
      return null;                                                    -- not the first arrival of the day
    end if;
    v_min := greatest(ceil(extract(epoch from (p_at - v_start)) / 60)::integer, 0);
  else
    if exists (select 1 from public.attendance_events x
               where x.employee_id = p_employee and x.event_type = 'check_out'
                 and (x.occurred_at at time zone v_tz)::date = v_day
                 and (x.occurred_at, x.id) > (p_at, p_event)) then
      return null;                                                    -- not the last departure of the day
    end if;
    v_min := greatest(ceil(extract(epoch from (v_end - p_at)) / 60)::integer, 0);
  end if;
  return case when v_min > v_grace then v_min else 0 end;
end;
$$;
revoke all on function private.punch_lateness(uuid, uuid, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin: company default
create or replace function public.admin_get_grace_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return (select jsonb_build_object('late_grace_min', c.late_grace_min, 'early_grace_min', c.early_grace_min)
          from public.companies c where c.id = v_company);
end;
$$;

create or replace function public.admin_set_grace_settings(p_late integer, p_early integer)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_late is null or p_early is null or p_late not between 0 and 240 or p_early not between 0 and 240 then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.companies set late_grace_min = p_late, early_grace_min = p_early where id = v_company;
  perform public.audit_write(v_company, 'company.grace_settings', 'company', v_company::text,
    jsonb_build_object('late_grace_min', p_late, 'early_grace_min', p_early));
  return public.admin_get_grace_settings();
end;
$$;

-- ---------------------------------------------------------------- admin: one employee (null = company value)
create or replace function public.admin_get_employee_grace(p_employee_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  return (select jsonb_build_object('late_grace_min', e.late_grace_min, 'early_grace_min', e.early_grace_min)
          from public.employees e where e.id = p_employee_id);
end;
$$;

create or replace function public.admin_set_employee_grace(p_employee_id uuid, p_late integer, p_early integer)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if (p_late is not null and p_late not between 0 and 240) or (p_early is not null and p_early not between 0 and 240) then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.employees set late_grace_min = p_late, early_grace_min = p_early where id = p_employee_id and company_id = v_company;
  perform public.audit_write(v_company, 'employee.grace', 'employee', p_employee_id::text,
    jsonb_build_object('late_grace_min', p_late, 'early_grace_min', p_early));
  return public.admin_get_employee_grace(p_employee_id);
end;
$$;

do $grants$
declare f text;
begin
  foreach f in array array[
    'public.admin_get_grace_settings()',
    'public.admin_set_grace_settings(integer, integer)',
    'public.admin_get_employee_grace(uuid)',
    'public.admin_set_employee_grace(uuid, integer, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$grants$;

-- ---------------------------------------------------------------- attendance list: + late_minutes, early_minutes
drop function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer);
create function public.admin_list_attendance(p_from timestamp with time zone default null, p_to timestamp with time zone default null,
  p_employee_id uuid default null, p_event_type public.attendance_event_type default null, p_limit integer default 50, p_offset integer default 0)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, email text, department text,
  event_type public.attendance_event_type, occurred_at timestamp with time zone, received_at timestamp with time zone,
  within_geofence boolean, geofence_enforced boolean, geofence_name text, distance_meters numeric, accuracy_meters numeric,
  latitude double precision, longitude double precision, authentication_method text, device_id text, total_count bigint,
  needs_review boolean, location_status text, source text, offline boolean, sync_delay_s integer, suspect text[],
  biometric text, missed_checkout boolean, late_minutes integer, early_minutes integer)
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    ev.id, ev.employee_id, emp.employee_number, emp.full_name, u.email::text, emp.department,
    ev.event_type, ev.occurred_at, ev.created_at, ev.within_geofence,
    coalesce((ev.metadata ->> 'geofence_enforced')::boolean, true),
    gf.name, ev.distance_from_geofence_meters, ev.accuracy_meters,
    extensions.st_y(ev.location::extensions.geometry), extensions.st_x(ev.location::extensions.geometry),
    ev.authentication_method, ev.device_id,
    count(*) over (),
    coalesce(ev.needs_review, false),
    ev.location_status,
    ev.metadata ->> 'source',
    coalesce((ev.metadata ->> 'offline')::boolean, false),
    (ev.metadata ->> 'sync_delay_s')::integer,
    coalesce(array(select jsonb_array_elements_text(ev.metadata -> 'suspect')), '{}'::text[]),
    ev.metadata ->> 'biometric',
    coalesce((ev.metadata ->> 'missed_checkout')::boolean, false),
    case when ev.event_type = 'check_in' then private.punch_lateness(ev.employee_id, ev.id, 'check_in', ev.occurred_at) end,
    case when ev.event_type = 'check_out' then private.punch_lateness(ev.employee_id, ev.id, 'check_out', ev.occurred_at) end
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  join auth.users u on u.id = ev.employee_id
  left join public.employee_geofences gf on gf.id = ev.geofence_id
  where ev.company_id = v_company
    and (p_from is null or ev.occurred_at >= p_from)
    and (p_to is null or ev.occurred_at < p_to)
    and (p_employee_id is null or ev.employee_id = p_employee_id)
    and (p_event_type is null or ev.event_type = p_event_type)
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 50), 1000), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;
revoke all on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) from public, anon;
grant execute on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) to authenticated;
