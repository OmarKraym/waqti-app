-- Rollback of 20261102100000_phase8b_biometric.sql: restores phase 8a / baseline functions; drops devices and tickets.
drop function public.employee_punch(uuid, text, text, double precision, double precision, double precision, text);
CREATE OR REPLACE FUNCTION public.employee_punch(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision, p_accuracy_m double precision DEFAULT NULL::double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me record;
  v_now timestamptz := now();
  v_result jsonb;
begin
  select * into me from public.require_active_employee();
  v_result := private.record_punch(
    me.employee_id, me.location_policy, me.outside_action, me.max_accuracy_m, me.timezone,
    p_request_id, p_expected_action, p_reading, p_lat, p_lng, p_accuracy_m,
    v_now, jsonb_build_object('source', 'pwa'));
  return v_result || jsonb_build_object('time_token', private.issue_time_token(me.employee_id, v_now));
end;
$function$
;

revoke all on function public.employee_punch(uuid, text, text, double precision, double precision, double precision) from public, anon, authenticated, service_role;
grant execute on function public.employee_punch(uuid, text, text, double precision, double precision, double precision) to authenticated;
grant execute on function public.employee_punch(uuid, text, text, double precision, double precision, double precision) to service_role;
create or replace function public.employee_attendance_state()
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_open public.attendance_sessions;
  v_started timestamptz;
  v_now timestamptz := now();
  v_win record;
begin
  select * into me from public.require_active_employee();
  perform private.close_missed_checkout(me.employee_id, v_now);

  select * into v_open from public.attendance_sessions s
  where s.employee_id = me.employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  if found then
    select ev.occurred_at into v_started from public.attendance_events ev where ev.id = v_open.check_in_event_id;
  end if;
  select * into v_win from private.punch_window(me.employee_id, case when v_open.id is null then 'check_in' else 'check_out' end, v_now);

  return jsonb_build_object(
    'employee', jsonb_build_object('full_name', me.full_name, 'employee_number', me.employee_number),
    'company', jsonb_build_object('name', me.company_name, 'timezone', me.timezone),
    'next_action', case when v_open.id is null then 'check_in' else 'check_out' end,
    'open_session', case when v_open.id is null then null else jsonb_build_object('started_at', v_started) end,
    'location_policy', me.location_policy,
    'outside_action', me.outside_action,
    'max_accuracy_m', me.max_accuracy_m,
    'punch_window', jsonb_build_object('allowed', v_win.allowed, 'opens_at', v_win.opens_at,
                                       'closes_at', v_win.closes_at, 'reason', v_win.reason),
    'recent_events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ev.id, 'action', ev.event_type, 'server_time', ev.occurred_at,
               'location_status', public.event_location_status(ev), 'needs_review', ev.needs_review)
             order by ev.occurred_at desc)
      from (select * from public.attendance_events x
            where x.employee_id = me.employee_id
            order by x.occurred_at desc limit 10) ev
    ), '[]'::jsonb),
    'server_time', v_now,
    'time_token', private.issue_time_token(me.employee_id, v_now)
  );
end;
$$;

revoke all on function public.employee_attendance_state() from public, anon;
grant execute on function public.employee_attendance_state() to authenticated;
create or replace function public.admin_get_employee_profile(p_employee_id uuid)
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

  return jsonb_build_object(
    'employee', (
      select to_jsonb(x) from (
        select e.id, e.employee_number, e.full_name, e.department, e.job_title, e.gender,
               e.birth_date, e.hire_date, e.work_location_id, e.is_active, e.geofence_required,
               e.location_policy, e.outside_action
        from public.employees e where e.id = p_employee_id and e.company_id = v_company
      ) x
    ),
    'base_salary', (select c.base_salary from public.employee_compensation c
                    where c.employee_id = p_employee_id and c.company_id = v_company),
    'components', coalesce((
      select jsonb_agg(jsonb_build_object('name', s.name, 'amount', s.amount) order by s.sort_order, s.id)
      from public.employee_salary_components s where s.employee_id = p_employee_id and s.company_id = v_company
    ), '[]'::jsonb),
    'schedule', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', w.weekday, 'is_workday', w.is_workday,
        'start_time', to_char(w.start_time, 'HH24:MI'), 'end_time', to_char(w.end_time, 'HH24:MI')
      ) order by w.weekday)
      from public.employee_work_schedules w where w.employee_id = p_employee_id and w.company_id = v_company
    ), '[]'::jsonb),
    'leave', coalesce((
      select jsonb_object_agg(l.leave_type, l.days)
      from public.employee_leave_entitlements l where l.employee_id = p_employee_id and l.company_id = v_company
    ), '{}'::jsonb),
    'punch_windows', (
      select jsonb_build_object('in_before_min', e.in_before_min, 'in_after_min', e.in_after_min,
                                'out_before_min', e.out_before_min, 'out_after_min', e.out_after_min)
      from public.employees e where e.id = p_employee_id)
  );
end;
$$;

drop function public.admin_list_employees();
CREATE OR REPLACE FUNCTION public.admin_list_employees()
 RETURNS TABLE(id uuid, email text, full_name text, employee_number text, department text, is_active boolean, geofence_required boolean, created_at timestamp with time zone, geofence_id uuid, geofence_name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric, job_title text, gender text, birth_date date, hire_date date, work_location_id uuid, work_location_name text, geofence_inherited boolean, location_policy text, outside_action text)
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
    e.location_policy, e.outside_action
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
$function$
;

revoke all on function public.admin_list_employees() from public, anon, authenticated, service_role;
grant execute on function public.admin_list_employees() to authenticated;
grant execute on function public.admin_list_employees() to service_role;
drop function public.admin_remove_device(uuid);
drop function public.service_webauthn_issue_ticket(uuid, text, bigint, uuid);
drop function public.service_webauthn_register(uuid, text, text, bigint, text[], text);
drop function public.service_webauthn_take_challenge(uuid, text);
drop function public.service_webauthn_put_challenge(uuid, text, text);
drop function public.employee_webauthn_context();
drop function private.b64u_decode(text);
drop function private.b64u_encode(bytea);
drop table private.punch_tickets;
drop table private.webauthn_challenges;
drop table public.webauthn_credentials;
