-- Rollback of phase 19b: no deduction policies. The policies already saved are deleted with the table (they exist only
-- for the deduction, which nothing else uses yet).
-- the attendance list goes back to phase 12 (no deduction columns)
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
drop function if exists private.punch_deduction(uuid, uuid, timestamptz);
drop function if exists public.admin_preview_deduction(jsonb, integer[]);
drop function if exists public.admin_delete_deduction_policy(uuid);
drop function if exists public.admin_save_deduction_policy(uuid, date, text, jsonb);
drop function if exists public.admin_list_deduction_policies();
drop function if exists private.deduction_policy_json(public.deduction_policies, date);
drop function if exists private.late_deduction(uuid, date, integer);
drop function if exists private.deduction_calc(text, jsonb, integer);
drop function if exists private.deduction_params_ok(text, jsonb);
drop function if exists private.deduction_params_clean(text, jsonb);
drop function if exists private.json_int(jsonb, integer, integer);
drop table if exists public.deduction_policies;
