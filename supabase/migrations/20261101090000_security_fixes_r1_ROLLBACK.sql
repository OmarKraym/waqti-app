-- Rollback of 20261101090000_security_fixes_r1.sql: restores the functions and grants exactly as before.
grant execute on function public.employee_punch_offline(uuid, text, text, double precision, double precision, double precision, text, timestamp with time zone, timestamp with time zone, bigint, timestamp with time zone) to authenticated;
grant execute on function public.record_attendance(public.attendance_event_type, double precision, double precision, numeric, text, text, uuid, timestamp with time zone) to authenticated;
CREATE OR REPLACE FUNCTION public.require_company_admin()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_company uuid := public.admin_company_id();
begin
  if v_company is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return v_company;
end;
$function$

;
CREATE OR REPLACE FUNCTION private.record_punch(p_employee_id uuid, p_policy text, p_outside_action text, p_max_accuracy_m numeric, p_timezone text, p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time timestamp with time zone, p_meta jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_saved jsonb;
  v_open_id uuid;
  v_action public.attendance_event_type;
  v_has_point boolean;
  v_point extensions.geography;
  v_geofence public.employee_geofences;
  v_distance numeric;
  v_status text;
  v_review boolean := false;
  v_event_id uuid;
begin
  if p_request_id is null
     or p_reading is null or p_reading not in ('ok', 'denied', 'unavailable', 'timeout', 'unsupported', 'not_requested')
     or p_expected_action is null or p_expected_action not in ('check_in', 'check_out') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  v_has_point := p_reading = 'ok' and p_lat is not null and p_lng is not null
                 and p_lat between -90 and 90 and p_lng between -180 and 180
                 and p_accuracy_m is not null and p_accuracy_m >= 0;

  -- One punch at a time per employee (two phones, or an offline batch).
  perform 1 from public.employees where id = p_employee_id for update;

  -- Idempotency: the same request_id never records twice.
  v_saved := private.existing_punch(p_request_id, p_employee_id);
  if v_saved is not null then
    return v_saved;
  end if;

  -- Events must stay in time order (an offline punch cannot go before an existing event).
  if exists (select 1 from public.attendance_events
             where employee_id = p_employee_id and occurred_at >= p_time) then
    raise exception 'time_order' using errcode = 'P0001';
  end if;

  -- Rate limit: max 5 punches within 60 seconds of this punch's time.
  if (select count(*) from public.attendance_events
      where employee_id = p_employee_id and occurred_at > p_time - interval '60 seconds') >= 5 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  -- Real next action (server state), compared with what the employee saw.
  select s.id into v_open_id from public.attendance_sessions s
  where s.employee_id = p_employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  v_action := case when v_open_id is null then 'check_in' else 'check_out' end;
  if v_action::text <> p_expected_action then
    raise exception 'state_changed' using errcode = 'P0001';
  end if;

  -- Location result (server decides; the device only reports).
  if p_policy = 'none' then
    v_status := 'not_requested';
    v_has_point := false;
  elsif not v_has_point then
    v_status := 'unavailable';
  elsif p_accuracy_m > p_max_accuracy_m then
    v_status := 'inaccurate';
  elsif p_policy = 'record' then
    v_status := 'recorded';
  end if;

  if v_has_point then
    v_point := extensions.st_geogfromtext(format('SRID=4326;POINT(%s %s)', p_lng, p_lat));
  end if;

  if p_policy = 'geofence' then
    select * into v_geofence from public.employee_geofences g
    where g.employee_id = p_employee_id and g.is_active
      and g.valid_from <= p_time and (g.valid_until is null or g.valid_until > p_time)
    order by g.created_at desc limit 1;
    if not found then
      -- offline punch dated before the current area was set: use the area active now
      select * into v_geofence from public.employee_geofences g
      where g.employee_id = p_employee_id and g.is_active and g.valid_until is null
      order by g.created_at desc limit 1;
      if not found then
        raise exception 'geofence_not_configured' using errcode = '22023';
      end if;
    end if;
    if v_has_point then
      v_distance := round(extensions.st_distance(v_point, v_geofence.center)::numeric, 2);
    end if;
    if v_status is null then
      v_status := case when v_distance <= v_geofence.radius_meters then 'inside' else 'outside' end;
    end if;
    if v_status <> 'inside' then
      if p_outside_action = 'reject' then
        raise exception '%', case v_status
          when 'outside' then 'outside_geofence'
          when 'inaccurate' then 'location_inaccurate'
          else 'location_required' end
          using errcode = '22023';
      end if;
      v_review := true;
    end if;
  end if;

  insert into public.attendance_events (
    employee_id, event_type, occurred_at, location, accuracy_meters,
    geofence_id, distance_from_geofence_meters, within_geofence,
    authentication_method, request_id, location_status, needs_review, location_policy, metadata
  ) values (
    p_employee_id, v_action, p_time, v_point, case when v_has_point then round(p_accuracy_m::numeric, 2) end,
    v_geofence.id, v_distance,
    case when p_policy = 'geofence' then v_status = 'inside' else true end,
    'password', p_request_id, v_status, v_review, p_policy,
    jsonb_build_object('geofence_enforced', p_policy = 'geofence', 'reading', p_reading,
                       'outside_action', p_outside_action) || coalesce(p_meta, '{}'::jsonb)
  ) returning id into v_event_id;

  if v_action = 'check_in' then
    insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status)
    values (p_employee_id, (p_time at time zone p_timezone)::date, v_event_id, 'open');
  else
    update public.attendance_sessions set check_out_event_id = v_event_id, status = 'closed'
    where id = v_open_id;
  end if;

  return jsonb_build_object(
    'event_id', v_event_id, 'action', v_action, 'server_time', p_time,
    'location_status', v_status, 'needs_review', v_review, 'duplicate', false);
end;
$function$

;
drop function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer);
CREATE OR REPLACE FUNCTION public.admin_list_attendance(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_employee_id uuid DEFAULT NULL::uuid, p_event_type attendance_event_type DEFAULT NULL::attendance_event_type, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(event_id uuid, employee_id uuid, employee_number text, full_name text, email text, department text, event_type attendance_event_type, occurred_at timestamp with time zone, received_at timestamp with time zone, within_geofence boolean, geofence_enforced boolean, geofence_name text, distance_meters numeric, accuracy_meters numeric, latitude double precision, longitude double precision, authentication_method text, device_id text, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
    count(*) over ()
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
$function$

;
revoke all on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) from public, anon;
grant execute on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) to authenticated;
create or replace function public.employee_save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
begin
  select * into me from public.require_active_employee();
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or p_p256dh is null or length(p_p256dh) not between 80 and 100 or p_auth is null or length(p_auth) not between 16 and 30 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  -- The same phone used by another account before: the device now belongs to me.
  insert into public.push_subscriptions (user_id, company_id, endpoint, p256dh, auth, user_agent)
  values (me.employee_id, me.company_id, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, company_id = excluded.company_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, fail_count = 0;
  insert into public.notification_settings (employee_id, company_id) values (me.employee_id, me.company_id)
  on conflict (employee_id) do nothing;
end;
$$;
CREATE OR REPLACE FUNCTION public.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.platform_admins p where p.user_id = (select auth.uid()))
$function$
;
drop function private.is_push_endpoint(text);
set search_path = public;
grant INSERT on employee_geofences to anon;
grant SELECT on employee_geofences to anon;
grant UPDATE on employee_geofences to anon;
grant DELETE on employee_geofences to anon;
grant TRUNCATE on employee_geofences to anon;
grant REFERENCES on employee_geofences to anon;
grant TRIGGER on employee_geofences to anon;
grant INSERT on employee_geofences to authenticated;
grant SELECT on employee_geofences to authenticated;
grant UPDATE on employee_geofences to authenticated;
grant DELETE on employee_geofences to authenticated;
grant TRUNCATE on employee_geofences to authenticated;
grant REFERENCES on employee_geofences to authenticated;
grant TRIGGER on employee_geofences to authenticated;
grant INSERT on attendance_sessions to anon;
grant SELECT on attendance_sessions to anon;
grant UPDATE on attendance_sessions to anon;
grant DELETE on attendance_sessions to anon;
grant TRUNCATE on attendance_sessions to anon;
grant REFERENCES on attendance_sessions to anon;
grant TRIGGER on attendance_sessions to anon;
grant SELECT on attendance_sessions to authenticated;
grant TRUNCATE on attendance_sessions to authenticated;
grant REFERENCES on attendance_sessions to authenticated;
grant TRIGGER on attendance_sessions to authenticated;
grant INSERT on employees to anon;
grant SELECT on employees to anon;
grant UPDATE on employees to anon;
grant DELETE on employees to anon;
grant TRUNCATE on employees to anon;
grant REFERENCES on employees to anon;
grant TRIGGER on employees to anon;
grant INSERT on employees to authenticated;
grant SELECT on employees to authenticated;
grant UPDATE on employees to authenticated;
grant DELETE on employees to authenticated;
grant TRUNCATE on employees to authenticated;
grant REFERENCES on employees to authenticated;
grant TRIGGER on employees to authenticated;
grant INSERT on attendance_events to anon;
grant SELECT on attendance_events to anon;
grant UPDATE on attendance_events to anon;
grant DELETE on attendance_events to anon;
grant TRUNCATE on attendance_events to anon;
grant REFERENCES on attendance_events to anon;
grant TRIGGER on attendance_events to anon;
grant SELECT on attendance_events to authenticated;
grant TRUNCATE on attendance_events to authenticated;
grant REFERENCES on attendance_events to authenticated;
grant TRIGGER on attendance_events to authenticated;
reset search_path;
