-- Production baseline (phases 1-3): the functions as they were in production before the phase 4 migration
-- (later migrations replace some of them). Exported read-only (security audit SEC-011). Do NOT run on production.
CREATE OR REPLACE FUNCTION private.existing_punch(p_request_id uuid, p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prev public.attendance_events;
begin
  select * into v_prev from public.attendance_events where request_id = p_request_id;
  if not found then
    return null;
  end if;
  if v_prev.employee_id <> p_employee_id then
    raise exception 'invalid_input' using errcode = '22023';  -- never reveal another user's event
  end if;
  return jsonb_build_object(
    'event_id', v_prev.id, 'action', v_prev.event_type, 'server_time', v_prev.occurred_at,
    'location_status', public.event_location_status(v_prev), 'needs_review', v_prev.needs_review,
    'duplicate', true);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.issue_time_token(p_employee_id uuid, p_at timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select 'v1.' || ms || '.' ||
         encode(extensions.hmac(convert_to('v1|' || p_employee_id::text || '|' || ms, 'UTF8'), s.value, 'sha256'), 'hex')
  from (select (floor(extract(epoch from p_at) * 1000))::bigint::text as ms) t,
       private.app_secrets s
  where s.name = 'time_token_key'
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

CREATE OR REPLACE FUNCTION private.verify_time_token(p_token text, p_employee_id uuid)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_parts text[] := string_to_array(coalesce(p_token, ''), '.');
  v_ms bigint;
  v_key bytea;
begin
  if array_length(v_parts, 1) <> 3 or v_parts[1] <> 'v1' or v_parts[2] !~ '^[0-9]{10,16}$' then
    return null;
  end if;
  select value into v_key from private.app_secrets where name = 'time_token_key';
  if encode(extensions.hmac(convert_to('v1|' || p_employee_id::text || '|' || v_parts[2], 'UTF8'), v_key, 'sha256'), 'hex') <> v_parts[3] then
    return null;
  end if;
  v_ms := v_parts[2]::bigint;
  return to_timestamp(v_ms / 1000.0);
end;
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.admin_company_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select m.company_id
  from public.company_members m
  join public.companies c on c.id = m.company_id and c.is_active
  join public.employees e on e.id = m.user_id and e.is_active
  where m.user_id = (select auth.uid()) and m.role = 'company_admin'
$function$
;

CREATE OR REPLACE FUNCTION public.admin_get_company_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  return (
    select jsonb_build_object(
      'id', c.id, 'name', c.name, 'timezone', c.timezone,
      'default_location_policy', c.default_location_policy,
      'default_outside_action', c.default_outside_action,
      'max_accuracy_m', c.max_accuracy_m)
    from public.companies c where c.id = v_company
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_get_employee_profile(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    ), '{}'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_get_leave_policy()
 RETURNS TABLE(age_threshold integer, days_below numeric, days_at_or_above numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  -- A company without its own row sees the defaults (50 years / 30 / 45 days).
  return query
  select coalesce(lp.age_threshold, 50)::integer, coalesce(lp.days_below, 30), coalesce(lp.days_at_or_above, 45)
  from (select 1) one
  left join public.leave_policy lp on lp.company_id = v_company;
end;
$function$
;

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

CREATE OR REPLACE FUNCTION public.admin_list_work_locations()
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
$function$
;

CREATE OR REPLACE FUNCTION public.admin_save_employee_profile(p_employee_id uuid, p_employee_number text, p_full_name text, p_department text, p_job_title text, p_gender text, p_birth_date date, p_hire_date date, p_work_location_id uuid, p_is_active boolean, p_geofence_required boolean, p_base_salary numeric, p_components jsonb, p_schedule jsonb, p_leave jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
  v_code text := btrim(coalesce(p_employee_number, ''));
  v_components jsonb := coalesce(p_components, '[]'::jsonb);
  v_leave jsonb := coalesce(p_leave, '{}'::jsonb);
  v_item jsonb;
  v_key text;
  v_val jsonb;
  v_wd int;
  v_start time;
  v_end time;
  v_seen int[] := '{}';
  v_amount numeric;
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if p_employee_id = auth.uid() and not coalesce(p_is_active, true) then
    raise exception 'cannot_deactivate_self' using errcode = '22023';
  end if;

  if coalesce(btrim(p_full_name), '') = '' or length(btrim(p_full_name)) > 100 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if length(v_code) not between 1 and 30 then
    raise exception 'invalid_employee_number' using errcode = '22023';
  end if;
  if coalesce(btrim(p_department), '') = '' or length(btrim(p_department)) > 100 then
    raise exception 'invalid_department' using errcode = '22023';
  end if;
  if coalesce(btrim(p_job_title), '') = '' or length(btrim(p_job_title)) > 100 then
    raise exception 'invalid_job_title' using errcode = '22023';
  end if;
  if p_gender is null or p_gender not in ('male', 'female') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  if p_birth_date is null or p_hire_date is null
     or p_birth_date <= date '1900-01-01'
     or p_birth_date >= p_hire_date
     or p_hire_date > current_date + 365 then
    raise exception 'invalid_dates' using errcode = '22023';
  end if;
  if p_work_location_id is null
     or not exists (select 1 from public.work_locations where id = p_work_location_id and company_id = v_company) then
    raise exception 'invalid_work_location' using errcode = '22023';
  end if;
  if p_base_salary is null or p_base_salary < 0 or p_base_salary >= 1000000000 then
    raise exception 'invalid_salary' using errcode = '22023';
  end if;

  if jsonb_typeof(v_components) <> 'array' or jsonb_array_length(v_components) > 30 then
    raise exception 'invalid_components' using errcode = '22023';
  end if;
  for v_item in select * from jsonb_array_elements(v_components) loop
    v_amount := (v_item ->> 'amount')::numeric;
    if coalesce(btrim(v_item ->> 'name'), '') = '' or length(btrim(v_item ->> 'name')) > 100
       or v_amount is null or v_amount < 0 or v_amount >= 1000000000 then
      raise exception 'invalid_components' using errcode = '22023';
    end if;
  end loop;

  if jsonb_typeof(p_schedule) is distinct from 'array' or jsonb_array_length(p_schedule) <> 7 then
    raise exception 'invalid_schedule' using errcode = '22023';
  end if;
  for v_item in select * from jsonb_array_elements(p_schedule) loop
    v_wd := (v_item ->> 'weekday')::int;
    if v_wd is null or v_wd not between 0 and 6 or v_wd = any(v_seen)
       or jsonb_typeof(v_item -> 'is_workday') is distinct from 'boolean' then
      raise exception 'invalid_schedule' using errcode = '22023';
    end if;
    v_seen := v_seen || v_wd;
    if (v_item ->> 'is_workday')::boolean then
      v_start := (v_item ->> 'start_time')::time;
      v_end := (v_item ->> 'end_time')::time;
      if v_start is null or v_end is null or v_end <= v_start then
        raise exception 'invalid_schedule' using errcode = '22023';
      end if;
    end if;
  end loop;

  if jsonb_typeof(v_leave) <> 'object' then
    raise exception 'invalid_leave' using errcode = '22023';
  end if;
  for v_key, v_val in select * from jsonb_each(v_leave) loop
    if v_key not in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid') then
      raise exception 'invalid_leave' using errcode = '22023';
    end if;
    if jsonb_typeof(v_val) = 'null' then
      continue;
    end if;
    if jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::numeric not between 0 and 366 then
      raise exception 'invalid_leave' using errcode = '22023';
    end if;
    if v_key = 'maternity' and p_gender <> 'female' then
      raise exception 'maternity_female_only' using errcode = '22023';
    end if;
  end loop;

  update public.employees
  set employee_number = v_code,
      full_name = btrim(p_full_name),
      department = btrim(p_department),
      job_title = btrim(p_job_title),
      gender = p_gender,
      birth_date = p_birth_date,
      hire_date = p_hire_date,
      work_location_id = p_work_location_id,
      is_active = coalesce(p_is_active, true),
      geofence_required = coalesce(p_geofence_required, true)
  where id = p_employee_id and company_id = v_company;

  insert into public.employee_compensation (employee_id, base_salary)
  values (p_employee_id, p_base_salary)
  on conflict (employee_id) do update set base_salary = excluded.base_salary, updated_at = now();

  delete from public.employee_salary_components where employee_id = p_employee_id and company_id = v_company;
  insert into public.employee_salary_components (employee_id, name, amount, sort_order)
  select p_employee_id, btrim(c.value ->> 'name'), (c.value ->> 'amount')::numeric, (c.ordinality - 1)::smallint
  from jsonb_array_elements(v_components) with ordinality as c(value, ordinality);

  delete from public.employee_work_schedules where employee_id = p_employee_id and company_id = v_company;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time)
  select p_employee_id,
         (s.value ->> 'weekday')::smallint,
         (s.value ->> 'is_workday')::boolean,
         case when (s.value ->> 'is_workday')::boolean then (s.value ->> 'start_time')::time end,
         case when (s.value ->> 'is_workday')::boolean then (s.value ->> 'end_time')::time end
  from jsonb_array_elements(p_schedule) as s(value);

  delete from public.employee_leave_entitlements where employee_id = p_employee_id and company_id = v_company;
  insert into public.employee_leave_entitlements (employee_id, leave_type, days)
  select p_employee_id, l.key, (l.value #>> '{}')::numeric
  from jsonb_each(v_leave) as l(key, value)
  where jsonb_typeof(l.value) = 'number';

  perform public.sync_employee_location_geofence(p_employee_id, false);

  -- Salary values are NOT written to the audit log (only the fact that the profile changed).
  perform public.audit_write(v_company, 'employee.save_profile', 'employee', p_employee_id::text,
    jsonb_build_object('employee_number', v_code, 'is_active', coalesce(p_is_active, true)));

exception
  when unique_violation then
    raise exception 'employee_number_exists' using errcode = '23505';
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
    raise exception 'invalid_input' using errcode = '22023';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_set_company_settings(p_default_location_policy text, p_default_outside_action text, p_max_accuracy_m numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_default_location_policy not in ('geofence', 'record', 'none')
     or p_default_outside_action not in ('flag', 'reject')
     or p_max_accuracy_m is null or p_max_accuracy_m not between 10 and 5000 then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.companies
  set default_location_policy = p_default_location_policy,
      default_outside_action = p_default_outside_action,
      max_accuracy_m = p_max_accuracy_m
  where id = v_company;
  perform public.audit_write(v_company, 'company.settings', 'company', v_company::text,
    jsonb_build_object('default_location_policy', p_default_location_policy,
                       'default_outside_action', p_default_outside_action, 'max_accuracy_m', p_max_accuracy_m));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_set_employee_location_policy(p_employee_id uuid, p_policy text, p_outside_action text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_policy not in ('geofence', 'record', 'none')
     or (p_outside_action is not null and p_outside_action not in ('flag', 'reject')) then
    raise exception 'invalid_policy' using errcode = '22023';
  end if;
  update public.employees
  set location_policy = p_policy,
      outside_action = case when p_policy = 'geofence' then p_outside_action end
  where id = p_employee_id and company_id = v_company;
  if not found then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  perform public.audit_write(v_company, 'employee.location_policy', 'employee', p_employee_id::text,
    jsonb_build_object('policy', p_policy, 'outside_action', p_outside_action));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_set_geofence(p_employee_id uuid, p_name text, p_latitude double precision, p_longitude double precision, p_radius_meters numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_company uuid := public.require_company_admin();
  v_id uuid;
begin
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_coordinates' using errcode = '22023';
  end if;
  if p_radius_meters is null or p_radius_meters < 20 or p_radius_meters > 10000 then
    raise exception 'invalid_radius' using errcode = '22023';
  end if;
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;

  update public.employee_geofences set is_active = false
  where employee_id = p_employee_id and company_id = v_company and is_active;

  insert into public.employee_geofences (employee_id, name, center, radius_meters, is_active)
  values (
    p_employee_id,
    coalesce(nullif(btrim(p_name), ''), 'نطاق العمل'),
    extensions.st_geogfromtext(format('SRID=4326;POINT(%s %s)', p_longitude, p_latitude)),
    p_radius_meters,
    true
  )
  returning id into v_id;

  perform public.audit_write(v_company, 'geofence.set', 'employee', p_employee_id::text,
    jsonb_build_object('lat', p_latitude, 'lng', p_longitude, 'radius_m', p_radius_meters));
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_set_leave_policy(p_age_threshold integer, p_days_below numeric, p_days_at_or_above numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_age_threshold is null or p_age_threshold not between 18 and 100
     or p_days_below is null or p_days_below not between 0 and 366
     or p_days_at_or_above is null or p_days_at_or_above not between 0 and 366 then
    raise exception 'invalid_policy' using errcode = '22023';
  end if;
  insert into public.leave_policy (company_id, age_threshold, days_below, days_at_or_above)
  values (v_company, p_age_threshold, p_days_below, p_days_at_or_above)
  on conflict (company_id) do update
    set age_threshold = excluded.age_threshold, days_below = excluded.days_below, days_at_or_above = excluded.days_at_or_above;
  perform public.audit_write(v_company, 'leave_policy.set', 'company', v_company::text,
    jsonb_build_object('age_threshold', p_age_threshold, 'days_below', p_days_below, 'days_at_or_above', p_days_at_or_above));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_set_location_geofence(p_location_id uuid, p_latitude double precision, p_longitude double precision, p_radius_meters numeric, p_override_individual boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_company uuid := public.require_company_admin();
  r record;
  v_result text;
  v_applied int := 0;
  v_unchanged int := 0;
  v_kept int := 0;
  v_total int := 0;
begin
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_coordinates' using errcode = '22023';
  end if;
  if p_radius_meters is null or p_radius_meters < 20 or p_radius_meters > 10000 then
    raise exception 'invalid_radius' using errcode = '22023';
  end if;
  if not exists (select 1 from public.work_locations where id = p_location_id and company_id = v_company) then
    raise exception 'location_not_found' using errcode = '22023';
  end if;

  update public.work_locations
  set geofence_center = extensions.st_geogfromtext(format('SRID=4326;POINT(%s %s)', p_longitude, p_latitude)),
      geofence_radius_meters = p_radius_meters,
      geofence_updated_at = now()
  where id = p_location_id and company_id = v_company;

  for r in select e.id from public.employees e where e.work_location_id = p_location_id and e.company_id = v_company loop
    v_total := v_total + 1;
    v_result := public.sync_employee_location_geofence(r.id, coalesce(p_override_individual, false));
    if v_result = 'applied' then v_applied := v_applied + 1;
    elsif v_result = 'unchanged' then v_unchanged := v_unchanged + 1;
    elsif v_result = 'kept_individual' then v_kept := v_kept + 1;
    end if;
  end loop;

  perform public.audit_write(v_company, 'work_location.set_geofence', 'work_location', p_location_id::text,
    jsonb_build_object('lat', p_latitude, 'lng', p_longitude, 'radius_m', p_radius_meters,
                       'override_individual', coalesce(p_override_individual, false), 'applied', v_applied));
  return jsonb_build_object('total', v_total, 'applied', v_applied, 'unchanged', v_unchanged, 'kept_individual', v_kept);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_update_employee(p_employee_id uuid, p_full_name text, p_department text, p_is_active boolean, p_geofence_required boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_employee_id = auth.uid() and not p_is_active then
    raise exception 'cannot_deactivate_self' using errcode = '22023';
  end if;
  if coalesce(btrim(p_full_name), '') = '' then
    raise exception 'invalid_name' using errcode = '22023';
  end if;

  update public.employees
  set full_name = btrim(p_full_name),
      department = nullif(btrim(coalesce(p_department, '')), ''),
      is_active = p_is_active,
      geofence_required = p_geofence_required
  where id = p_employee_id and company_id = v_company;

  if not found then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  perform public.audit_write(v_company, 'employee.update', 'employee', p_employee_id::text,
    jsonb_build_object('is_active', p_is_active, 'geofence_required', p_geofence_required));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_use_location_geofence(p_employee_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_company uuid := public.require_company_admin();
  v_loc_id uuid;
begin
  select e.work_location_id into v_loc_id from public.employees e where e.id = p_employee_id and e.company_id = v_company;
  if not found then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if v_loc_id is null then
    raise exception 'invalid_work_location' using errcode = '22023';
  end if;
  if not exists (select 1 from public.work_locations w
                 where w.id = v_loc_id and w.company_id = v_company and w.geofence_center is not null) then
    raise exception 'location_has_no_geofence' using errcode = '22023';
  end if;
  perform public.audit_write(v_company, 'geofence.use_location', 'employee', p_employee_id::text, '{}'::jsonb);
  return public.sync_employee_location_geofence(p_employee_id, true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.audit_write(p_company_id uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.audit_log (company_id, actor_id, action, target_type, target_id, details)
  values (p_company_id, (select auth.uid()), p_action, p_target_type, p_target_id, coalesce(p_details, '{}'::jsonb))
$function$
;

CREATE OR REPLACE FUNCTION public.current_company_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select m.company_id from public.company_members m where m.user_id = (select auth.uid())
$function$
;

CREATE OR REPLACE FUNCTION public.default_annual_leave_days(p_company_id uuid, p_birth_date date, p_on date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when date_part('year', age(p_on, p_birth_date)) >= lp.age_threshold then lp.days_at_or_above
    else lp.days_below
  end
  from public.leave_policy lp
  where lp.company_id = p_company_id and p_birth_date is not null
$function$
;

CREATE OR REPLACE FUNCTION public.employee_attendance_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me record;
  v_open public.attendance_sessions;
  v_started timestamptz;
  v_now timestamptz := now();
begin
  select * into me from public.require_active_employee();

  select * into v_open from public.attendance_sessions s
  where s.employee_id = me.employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  if found then
    select ev.occurred_at into v_started from public.attendance_events ev where ev.id = v_open.check_in_event_id;
  end if;

  return jsonb_build_object(
    'employee', jsonb_build_object('full_name', me.full_name, 'employee_number', me.employee_number),
    'company', jsonb_build_object('name', me.company_name, 'timezone', me.timezone),
    'next_action', case when v_open.id is null then 'check_in' else 'check_out' end,
    'open_session', case when v_open.id is null then null else jsonb_build_object('started_at', v_started) end,
    'location_policy', me.location_policy,
    'outside_action', me.outside_action,
    'max_accuracy_m', me.max_accuracy_m,
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
$function$
;

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

CREATE OR REPLACE FUNCTION public.employee_punch_offline(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time_token text, p_token_device_time timestamp with time zone, p_device_time timestamp with time zone, p_monotonic_ms bigint, p_device_now timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me record;
  v_now timestamptz := now();
  v_saved jsonb;
  v_token_time timestamptz;
  v_offset_then interval;
  v_offset_now interval;
  v_claimed timestamptz;
  v_mono timestamptz;
  v_tolerance constant interval := interval '120 seconds';
  v_result jsonb;
begin
  select * into me from public.require_active_employee();

  -- A retry of a punch that was already saved returns the saved answer (whatever the checks say now).
  v_saved := private.existing_punch(p_request_id, me.employee_id);
  if v_saved is not null then
    return v_saved || jsonb_build_object('time_token', private.issue_time_token(me.employee_id, v_now));
  end if;

  v_token_time := private.verify_time_token(p_time_token, me.employee_id);
  if v_token_time is null or p_token_device_time is null or p_device_time is null or p_device_now is null then
    raise exception 'time_unverified' using errcode = 'P0001';
  end if;

  -- 2. Phone clock offset must not change between the token and now.
  v_offset_then := v_token_time - p_token_device_time;
  v_offset_now := v_now - p_device_now;
  if abs(extract(epoch from (v_offset_now - v_offset_then))) > extract(epoch from v_tolerance) then
    raise exception 'clock_changed' using errcode = 'P0001';
  end if;

  -- Claimed time = phone time corrected by the known offset.
  v_claimed := p_device_time + v_offset_then;

  -- 3. Monotonic check when available. ONE-SIDED on purpose: phones may pause the monotonic clock
  --    while asleep, so it can only UNDER-count. If the phone clock says LESS time passed than the
  --    monotonic clock, the phone clock was moved back (punch made to look earlier) -> refused.
  if p_monotonic_ms is not null then
    if p_monotonic_ms < 0 then
      raise exception 'clock_changed' using errcode = 'P0001';
    end if;
    v_mono := v_token_time + make_interval(secs => p_monotonic_ms / 1000.0);
    if v_claimed < v_mono - v_tolerance then
      raise exception 'clock_changed' using errcode = 'P0001';
    end if;
  end if;

  -- 4. Bounds.
  if v_claimed < v_token_time - interval '5 seconds' or v_claimed > v_now + interval '5 seconds' then
    raise exception 'clock_changed' using errcode = 'P0001';
  end if;
  if v_claimed < v_now - interval '72 hours' then
    raise exception 'offline_too_old' using errcode = 'P0001';
  end if;
  if v_claimed > v_now then
    v_claimed := v_now;
  end if;

  v_result := private.record_punch(
    me.employee_id, me.location_policy, me.outside_action, me.max_accuracy_m, me.timezone,
    p_request_id, p_expected_action, p_reading, p_lat, p_lng, p_accuracy_m,
    v_claimed,
    jsonb_build_object(
      'source', 'pwa_offline',
      'offline', true,
      'token_time', v_token_time,
      'device_time', p_device_time,
      'monotonic_checked', p_monotonic_ms is not null,
      'sync_delay_s', round(extract(epoch from (v_now - v_claimed)))));
  return v_result || jsonb_build_object('time_token', private.issue_time_token(me.employee_id, v_now));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.event_location_status(ev attendance_events)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select coalesce(
    ev.location_status,
    case
      when coalesce((ev.metadata ->> 'geofence_enforced')::boolean, true) = false then 'recorded'
      when ev.within_geofence then 'inside'
      else 'outside'
    end)
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_profile()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_emp public.employees;
  v_base numeric;
  v_components_total numeric;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_emp from public.employees where id = v_uid;
  if not found then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if not v_emp.is_active then
    raise exception 'employee_not_active' using errcode = '42501';
  end if;

  select c.base_salary into v_base from public.employee_compensation c where c.employee_id = v_uid;
  select coalesce(sum(s.amount), 0) into v_components_total from public.employee_salary_components s where s.employee_id = v_uid;

  return jsonb_build_object(
    'employee', jsonb_build_object(
      'employee_number', v_emp.employee_number,
      'full_name', v_emp.full_name,
      'department', v_emp.department,
      'job_title', v_emp.job_title,
      'gender', v_emp.gender,
      'birth_date', v_emp.birth_date,
      'hire_date', v_emp.hire_date,
      'work_location_name', (select w.name from public.work_locations w where w.id = v_emp.work_location_id)
    ),
    'schedule', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', w.weekday, 'is_workday', w.is_workday,
        'start_time', to_char(w.start_time, 'HH24:MI'), 'end_time', to_char(w.end_time, 'HH24:MI')
      ) order by w.weekday)
      from public.employee_work_schedules w where w.employee_id = v_uid
    ), '[]'::jsonb),
    'salary', case when v_base is null then null else jsonb_build_object(
      'base_salary', v_base,
      'components', coalesce((
        select jsonb_agg(jsonb_build_object('name', s.name, 'amount', s.amount) order by s.sort_order, s.id)
        from public.employee_salary_components s where s.employee_id = v_uid
      ), '[]'::jsonb),
      'total', v_base + v_components_total
    ) end,
    'leave', coalesce((
      select jsonb_agg(q.item order by q.ord)
      from (
        select jsonb_build_object('type', l.leave_type, 'days', l.days, 'is_default', false) as item,
               array_position(array['annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid'], l.leave_type) as ord
        from public.employee_leave_entitlements l
        where l.employee_id = v_uid
        union all
        select jsonb_build_object('type', 'annual',
                 'days', coalesce(public.default_annual_leave_days(v_emp.company_id, v_emp.birth_date),
                                  case when date_part('year', age(current_date, v_emp.birth_date)) >= 50 then 45 else 30 end),
                 'is_default', true), 1
        where v_emp.birth_date is not null
          and not exists (select 1 from public.employee_leave_entitlements l2 where l2.employee_id = v_uid and l2.leave_type = 'annual')
      ) q
    ), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_schedule()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_active boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select e.is_active into v_active from public.employees e where e.id = v_uid;
  if not found then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if not v_active then
    raise exception 'employee_not_active' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'weekday', w.weekday,
      'is_workday', w.is_workday,
      'start_time', to_char(w.start_time, 'HH24:MI'),
      'end_time', to_char(w.end_time, 'HH24:MI')
    ) order by w.weekday)
    from public.employee_work_schedules w
    where w.employee_id = v_uid
  ), '[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid;
  v_role text;
  v_policy text;
begin
  begin
    v_company := nullif(new.raw_app_meta_data ->> 'company_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'invalid_company' using errcode = '22023';
  end;
  if v_company is null then
    return new;
  end if;

  select c.default_location_policy into v_policy from public.companies c where c.id = v_company and c.is_active;
  if not found then
    raise exception 'invalid_company' using errcode = '22023';
  end if;
  v_role := case when new.raw_app_meta_data ->> 'company_role' = 'company_admin' then 'company_admin' else 'employee' end;

  insert into public.employees (id, company_id, employee_number, full_name, department, location_policy, geofence_required)
  values (
    new.id,
    v_company,
    'EMP-' || upper(substr(replace(new.id::text, '-', ''), 1, 8)),
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1), 'موظف جديد'),
    new.raw_user_meta_data ->> 'department',
    v_policy,
    v_policy = 'geofence'
  )
  on conflict (id) do nothing;

  insert into public.company_members (user_id, company_id, role)
  values (new.id, v_company, v_role)
  on conflict (user_id) do nothing;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_manager()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select public.admin_company_id() is not null
$function$
;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.platform_admins p where p.user_id = (select auth.uid()))
$function$
;

CREATE OR REPLACE FUNCTION public.my_admin_context()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.platform_create_company(p_name text, p_timezone text DEFAULT 'Africa/Tripoli'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 1 and 150 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'invalid_timezone' using errcode = '22023';
  end if;
  insert into public.companies (name, timezone) values (btrim(p_name), p_timezone) returning id into v_id;
  insert into public.leave_policy (company_id) values (v_id);
  perform public.audit_write(v_id, 'platform.company_create', 'company', v_id::text, jsonb_build_object('name', btrim(p_name)));
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.platform_list_companies()
 RETURNS TABLE(id uuid, name text, timezone text, is_active boolean, employees_count bigint, admins_count bigint, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.platform_update_company(p_company_id uuid, p_name text, p_timezone text, p_is_active boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 1 and 150 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'invalid_timezone' using errcode = '22023';
  end if;
  update public.companies set name = btrim(p_name), timezone = p_timezone, is_active = coalesce(p_is_active, true)
  where id = p_company_id;
  if not found then
    raise exception 'company_not_found' using errcode = '22023';
  end if;
  perform public.audit_write(p_company_id, 'platform.company_update', 'company', p_company_id::text,
    jsonb_build_object('name', btrim(p_name), 'timezone', p_timezone, 'is_active', coalesce(p_is_active, true)));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prevent_company_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.company_id is distinct from old.company_id then
    raise exception 'company_change_not_allowed' using errcode = '42501';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_attendance(p_event_type attendance_event_type, p_latitude double precision, p_longitude double precision, p_accuracy_meters numeric DEFAULT NULL::numeric, p_device_id text DEFAULT NULL::text, p_authentication_method text DEFAULT 'biometric'::text, p_request_id uuid DEFAULT gen_random_uuid(), p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(event_id uuid, session_id uuid, event_type attendance_event_type, occurred_at timestamp with time zone, within_geofence boolean, distance_meters numeric, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_employee_id uuid := auth.uid();
  v_now timestamptz := now();   -- the ONLY time used for the record
  v_location extensions.geography := extensions.st_geogfromtext(
    format('SRID=4326;POINT(%s %s)', p_longitude, p_latitude)
  );
  v_geofence public.employee_geofences;
  v_required boolean;
  v_distance numeric;
  v_event_id uuid;
  v_session_id uuid;
begin
  if v_employee_id is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select e.geofence_required into v_required
  from public.employees e
  where e.id = v_employee_id and e.is_active;

  if not found then
    raise exception 'employee_not_active' using errcode = '42501';
  end if;

  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_coordinates' using errcode = '22023';
  end if;

  perform 1 from public.employees where id = v_employee_id for update;

  if p_event_type = 'check_in' and exists (
    select 1 from public.attendance_sessions
    where employee_id = v_employee_id and status = 'open'
  ) then
    raise exception 'attendance_already_open' using errcode = '23514';
  end if;

  if p_event_type = 'check_out' and not exists (
    select 1 from public.attendance_sessions
    where employee_id = v_employee_id and status = 'open'
  ) then
    raise exception 'no_open_session' using errcode = '23514';
  end if;

  if v_required then
    select * into v_geofence
    from public.employee_geofences
    where employee_id = v_employee_id
      and is_active
      and valid_from <= v_now
      and (valid_until is null or valid_until > v_now)
    order by created_at desc
    limit 1;

    if not found then
      raise exception 'geofence_not_configured' using errcode = '22023';
    end if;

    v_distance := round(extensions.st_distance(v_location, v_geofence.center)::numeric, 2);

    if v_distance > v_geofence.radius_meters then
      raise exception 'outside_geofence' using
        errcode = '22023',
        detail = format('distance_meters=%s,radius_meters=%s', v_distance, v_geofence.radius_meters);
    end if;
  end if;

  insert into public.attendance_events (
    employee_id, event_type, occurred_at, location, accuracy_meters,
    geofence_id, distance_from_geofence_meters, within_geofence,
    authentication_method, device_id, request_id, metadata
  ) values (
    v_employee_id, p_event_type, v_now, v_location, p_accuracy_meters,
    v_geofence.id, v_distance, true,
    p_authentication_method, p_device_id, p_request_id,
    jsonb_build_object(
      'geofence_enforced', v_required,
      -- what the client claimed, for review only; never used as the record time
      'client_claimed_time', case when p_occurred_at is distinct from v_now then p_occurred_at end
    )
  ) returning id into v_event_id;

  if p_event_type = 'check_in' then
    insert into public.attendance_sessions (
      employee_id, work_date, check_in_event_id, status
    ) values (
      v_employee_id, (v_now at time zone 'Africa/Tripoli')::date, v_event_id, 'open'
    ) returning id into v_session_id;
  else
    select s.id into v_session_id
    from public.attendance_sessions s
    where s.employee_id = v_employee_id and s.status = 'open'
    order by s.created_at desc
    limit 1
    for update;

    if v_session_id is null then
      raise exception 'no_open_session' using errcode = '22023';
    end if;

    update public.attendance_sessions
    set check_out_event_id = v_event_id, status = 'closed'
    where id = v_session_id;
  end if;

  return query select
    v_event_id,
    v_session_id,
    p_event_type,
    v_now,
    true,
    v_distance,
    case when p_event_type = 'check_in'
      then 'تم تسجيل الدخول بنجاح'
      else 'تم تسجيل الخروج بنجاح'
    end;
exception
  when unique_violation then
    raise exception 'duplicate_attendance_request' using errcode = '23505';
end;
$function$
;

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

CREATE OR REPLACE FUNCTION public.service_audit_write(p_company_id uuid, p_actor_id uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.audit_log (company_id, actor_id, action, target_type, target_id, details)
  values (p_company_id, p_actor_id, p_action, p_target_type, p_target_id, coalesce(p_details, '{}'::jsonb))
$function$
;

CREATE OR REPLACE FUNCTION public.service_revoke_user_sessions(p_user_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_count integer;
begin
  delete from auth.sessions where user_id = p_user_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_company_from_employee()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  select e.company_id into new.company_id from public.employees e where e.id = new.employee_id;
  if new.company_id is null then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_employee_location_geofence(p_employee_id uuid, p_force boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_loc_id uuid;
  v_loc public.work_locations;
  v_active public.employee_geofences;
  v_has_active boolean;
begin
  select e.work_location_id into v_loc_id from public.employees e where e.id = p_employee_id;
  if v_loc_id is null then
    return 'no_location';
  end if;
  select * into v_loc from public.work_locations w where w.id = v_loc_id;

  select * into v_active
  from public.employee_geofences g
  where g.employee_id = p_employee_id and g.is_active and g.valid_until is null
  limit 1;
  v_has_active := found;

  if v_has_active and v_active.source_location_id is null and not p_force then
    return 'kept_individual';
  end if;

  if v_loc.geofence_center is null then
    -- The new place has no geofence: a geofence copied from the OLD place must not stay.
    if v_has_active and v_active.source_location_id is not null then
      update public.employee_geofences set is_active = false where id = v_active.id;
      return 'removed_inherited';
    end if;
    return 'no_location_geofence';
  end if;

  if v_has_active
     and v_active.source_location_id = v_loc_id
     and v_active.radius_meters = v_loc.geofence_radius_meters
     and extensions.st_equals(v_active.center::extensions.geometry, v_loc.geofence_center::extensions.geometry) then
    return 'unchanged';
  end if;

  if v_has_active then
    update public.employee_geofences set is_active = false where id = v_active.id;
  end if;

  insert into public.employee_geofences (employee_id, name, center, radius_meters, is_active, source_location_id)
  values (p_employee_id, v_loc.name, v_loc.geofence_center, v_loc.geofence_radius_meters, true, v_loc_id);
  return 'applied';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_location_policy()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'INSERT' then
    if not new.geofence_required and new.location_policy = 'geofence' then
      new.location_policy := 'record';
    end if;
  elsif new.location_policy is distinct from old.location_policy then
    null;  -- the policy was set directly: it wins
  elsif new.geofence_required is distinct from old.geofence_required then
    -- old admin screen toggled the checkbox: on = geofence, off = keep 'none' if it was 'none', else 'record'
    new.location_policy := case
      when new.geofence_required then 'geofence'
      when old.location_policy = 'none' then 'none'
      else 'record' end;
  end if;
  new.geofence_required := (new.location_policy = 'geofence');
  return new;
end;
$function$
;

-- ACL
revoke all on function public.handle_new_auth_user() from public, anon, authenticated, service_role; grant execute on function public.handle_new_auth_user() to service_role;
revoke all on function public.is_manager() from public, anon, authenticated, service_role; grant execute on function public.is_manager() to authenticated; grant execute on function public.is_manager() to service_role;
revoke all on function public.my_admin_context() from public, anon, authenticated, service_role; grant execute on function public.my_admin_context() to authenticated; grant execute on function public.my_admin_context() to service_role;
revoke all on function public.record_attendance(p_event_type attendance_event_type, p_latitude double precision, p_longitude double precision, p_accuracy_meters numeric, p_device_id text, p_authentication_method text, p_request_id uuid, p_occurred_at timestamp with time zone) from public, anon, authenticated, service_role; grant execute on function public.record_attendance(p_event_type attendance_event_type, p_latitude double precision, p_longitude double precision, p_accuracy_meters numeric, p_device_id text, p_authentication_method text, p_request_id uuid, p_occurred_at timestamp with time zone) to authenticated; grant execute on function public.record_attendance(p_event_type attendance_event_type, p_latitude double precision, p_longitude double precision, p_accuracy_meters numeric, p_device_id text, p_authentication_method text, p_request_id uuid, p_occurred_at timestamp with time zone) to service_role;
revoke all on function public.audit_write(p_company_id uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb) from public, anon, authenticated, service_role; grant execute on function public.audit_write(p_company_id uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb) to service_role;
revoke all on function public.current_company_id() from public, anon, authenticated, service_role; grant execute on function public.current_company_id() to authenticated; grant execute on function public.current_company_id() to service_role;
revoke all on function public.is_platform_admin() from public, anon, authenticated, service_role; grant execute on function public.is_platform_admin() to authenticated; grant execute on function public.is_platform_admin() to service_role;
revoke all on function public.admin_company_id() from public, anon, authenticated, service_role; grant execute on function public.admin_company_id() to authenticated; grant execute on function public.admin_company_id() to service_role;
revoke all on function public.service_audit_write(p_company_id uuid, p_actor_id uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb) from public, anon, authenticated, service_role; grant execute on function public.service_audit_write(p_company_id uuid, p_actor_id uuid, p_action text, p_target_type text, p_target_id text, p_details jsonb) to service_role;
revoke all on function public.default_annual_leave_days(p_company_id uuid, p_birth_date date, p_on date) from public, anon, authenticated, service_role; grant execute on function public.default_annual_leave_days(p_company_id uuid, p_birth_date date, p_on date) to service_role;
revoke all on function public.service_revoke_user_sessions(p_user_id uuid) from public, anon, authenticated, service_role; grant execute on function public.service_revoke_user_sessions(p_user_id uuid) to service_role;
revoke all on function public.sync_employee_location_geofence(p_employee_id uuid, p_force boolean) from public, anon, authenticated, service_role; grant execute on function public.sync_employee_location_geofence(p_employee_id uuid, p_force boolean) to service_role;
revoke all on function public.get_my_schedule() from public, anon, authenticated, service_role; grant execute on function public.get_my_schedule() to authenticated; grant execute on function public.get_my_schedule() to service_role;
revoke all on function public.set_updated_at() from public, anon, authenticated, service_role; grant execute on function public.set_updated_at() to public; grant execute on function public.set_updated_at() to anon; grant execute on function public.set_updated_at() to authenticated; grant execute on function public.set_updated_at() to service_role;
revoke all on function public.set_company_from_employee() from public, anon, authenticated, service_role; grant execute on function public.set_company_from_employee() to service_role;
revoke all on function public.prevent_company_change() from public, anon, authenticated, service_role; grant execute on function public.prevent_company_change() to service_role;
revoke all on function public.sync_location_policy() from public, anon, authenticated, service_role; grant execute on function public.sync_location_policy() to service_role;
revoke all on function public.require_company_admin() from public, anon, authenticated, service_role; grant execute on function public.require_company_admin() to service_role;
revoke all on function public.admin_list_employees() from public, anon, authenticated, service_role; grant execute on function public.admin_list_employees() to authenticated; grant execute on function public.admin_list_employees() to service_role;
revoke all on function public.admin_update_employee(p_employee_id uuid, p_full_name text, p_department text, p_is_active boolean, p_geofence_required boolean) from public, anon, authenticated, service_role; grant execute on function public.admin_update_employee(p_employee_id uuid, p_full_name text, p_department text, p_is_active boolean, p_geofence_required boolean) to authenticated; grant execute on function public.admin_update_employee(p_employee_id uuid, p_full_name text, p_department text, p_is_active boolean, p_geofence_required boolean) to service_role;
revoke all on function public.admin_set_geofence(p_employee_id uuid, p_name text, p_latitude double precision, p_longitude double precision, p_radius_meters numeric) from public, anon, authenticated, service_role; grant execute on function public.admin_set_geofence(p_employee_id uuid, p_name text, p_latitude double precision, p_longitude double precision, p_radius_meters numeric) to authenticated; grant execute on function public.admin_set_geofence(p_employee_id uuid, p_name text, p_latitude double precision, p_longitude double precision, p_radius_meters numeric) to service_role;
revoke all on function public.admin_list_attendance(p_from timestamp with time zone, p_to timestamp with time zone, p_employee_id uuid, p_event_type attendance_event_type, p_limit integer, p_offset integer) from public, anon, authenticated, service_role; grant execute on function public.admin_list_attendance(p_from timestamp with time zone, p_to timestamp with time zone, p_employee_id uuid, p_event_type attendance_event_type, p_limit integer, p_offset integer) to authenticated; grant execute on function public.admin_list_attendance(p_from timestamp with time zone, p_to timestamp with time zone, p_employee_id uuid, p_event_type attendance_event_type, p_limit integer, p_offset integer) to service_role;
revoke all on function public.admin_list_work_locations() from public, anon, authenticated, service_role; grant execute on function public.admin_list_work_locations() to authenticated; grant execute on function public.admin_list_work_locations() to service_role;
revoke all on function public.admin_add_work_location(p_name text) from public, anon, authenticated, service_role; grant execute on function public.admin_add_work_location(p_name text) to authenticated; grant execute on function public.admin_add_work_location(p_name text) to service_role;
revoke all on function public.admin_set_location_geofence(p_location_id uuid, p_latitude double precision, p_longitude double precision, p_radius_meters numeric, p_override_individual boolean) from public, anon, authenticated, service_role; grant execute on function public.admin_set_location_geofence(p_location_id uuid, p_latitude double precision, p_longitude double precision, p_radius_meters numeric, p_override_individual boolean) to authenticated; grant execute on function public.admin_set_location_geofence(p_location_id uuid, p_latitude double precision, p_longitude double precision, p_radius_meters numeric, p_override_individual boolean) to service_role;
revoke all on function public.admin_use_location_geofence(p_employee_id uuid) from public, anon, authenticated, service_role; grant execute on function public.admin_use_location_geofence(p_employee_id uuid) to authenticated; grant execute on function public.admin_use_location_geofence(p_employee_id uuid) to service_role;
revoke all on function public.admin_get_leave_policy() from public, anon, authenticated, service_role; grant execute on function public.admin_get_leave_policy() to authenticated; grant execute on function public.admin_get_leave_policy() to service_role;
revoke all on function public.admin_set_leave_policy(p_age_threshold integer, p_days_below numeric, p_days_at_or_above numeric) from public, anon, authenticated, service_role; grant execute on function public.admin_set_leave_policy(p_age_threshold integer, p_days_below numeric, p_days_at_or_above numeric) to authenticated; grant execute on function public.admin_set_leave_policy(p_age_threshold integer, p_days_below numeric, p_days_at_or_above numeric) to service_role;
revoke all on function public.admin_get_employee_profile(p_employee_id uuid) from public, anon, authenticated, service_role; grant execute on function public.admin_get_employee_profile(p_employee_id uuid) to authenticated; grant execute on function public.admin_get_employee_profile(p_employee_id uuid) to service_role;
revoke all on function public.admin_save_employee_profile(p_employee_id uuid, p_employee_number text, p_full_name text, p_department text, p_job_title text, p_gender text, p_birth_date date, p_hire_date date, p_work_location_id uuid, p_is_active boolean, p_geofence_required boolean, p_base_salary numeric, p_components jsonb, p_schedule jsonb, p_leave jsonb) from public, anon, authenticated, service_role; grant execute on function public.admin_save_employee_profile(p_employee_id uuid, p_employee_number text, p_full_name text, p_department text, p_job_title text, p_gender text, p_birth_date date, p_hire_date date, p_work_location_id uuid, p_is_active boolean, p_geofence_required boolean, p_base_salary numeric, p_components jsonb, p_schedule jsonb, p_leave jsonb) to authenticated; grant execute on function public.admin_save_employee_profile(p_employee_id uuid, p_employee_number text, p_full_name text, p_department text, p_job_title text, p_gender text, p_birth_date date, p_hire_date date, p_work_location_id uuid, p_is_active boolean, p_geofence_required boolean, p_base_salary numeric, p_components jsonb, p_schedule jsonb, p_leave jsonb) to service_role;
revoke all on function public.get_my_profile() from public, anon, authenticated, service_role; grant execute on function public.get_my_profile() to authenticated; grant execute on function public.get_my_profile() to service_role;
revoke all on function public.admin_get_company_settings() from public, anon, authenticated, service_role; grant execute on function public.admin_get_company_settings() to authenticated; grant execute on function public.admin_get_company_settings() to service_role;
revoke all on function public.admin_set_company_settings(p_default_location_policy text, p_default_outside_action text, p_max_accuracy_m numeric) from public, anon, authenticated, service_role; grant execute on function public.admin_set_company_settings(p_default_location_policy text, p_default_outside_action text, p_max_accuracy_m numeric) to authenticated; grant execute on function public.admin_set_company_settings(p_default_location_policy text, p_default_outside_action text, p_max_accuracy_m numeric) to service_role;
revoke all on function public.admin_set_employee_location_policy(p_employee_id uuid, p_policy text, p_outside_action text) from public, anon, authenticated, service_role; grant execute on function public.admin_set_employee_location_policy(p_employee_id uuid, p_policy text, p_outside_action text) to authenticated; grant execute on function public.admin_set_employee_location_policy(p_employee_id uuid, p_policy text, p_outside_action text) to service_role;
revoke all on function public.platform_list_companies() from public, anon, authenticated, service_role; grant execute on function public.platform_list_companies() to authenticated; grant execute on function public.platform_list_companies() to service_role;
revoke all on function public.platform_create_company(p_name text, p_timezone text) from public, anon, authenticated, service_role; grant execute on function public.platform_create_company(p_name text, p_timezone text) to authenticated; grant execute on function public.platform_create_company(p_name text, p_timezone text) to service_role;
revoke all on function public.platform_update_company(p_company_id uuid, p_name text, p_timezone text, p_is_active boolean) from public, anon, authenticated, service_role; grant execute on function public.platform_update_company(p_company_id uuid, p_name text, p_timezone text, p_is_active boolean) to authenticated; grant execute on function public.platform_update_company(p_company_id uuid, p_name text, p_timezone text, p_is_active boolean) to service_role;
revoke all on function public.event_location_status(ev attendance_events) from public, anon, authenticated, service_role; grant execute on function public.event_location_status(ev attendance_events) to service_role;
revoke all on function private.verify_time_token(p_token text, p_employee_id uuid) from public, anon, authenticated, service_role;
revoke all on function private.existing_punch(p_request_id uuid, p_employee_id uuid) from public, anon, authenticated, service_role;
revoke all on function private.record_punch(p_employee_id uuid, p_policy text, p_outside_action text, p_max_accuracy_m numeric, p_timezone text, p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time timestamp with time zone, p_meta jsonb) from public, anon, authenticated, service_role;
revoke all on function public.require_active_employee() from public, anon, authenticated, service_role; grant execute on function public.require_active_employee() to service_role;
revoke all on function private.issue_time_token(p_employee_id uuid, p_at timestamp with time zone) from public, anon, authenticated, service_role;
revoke all on function public.employee_punch(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision) from public, anon, authenticated, service_role; grant execute on function public.employee_punch(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision) to authenticated; grant execute on function public.employee_punch(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision) to service_role;
revoke all on function public.employee_attendance_state() from public, anon, authenticated, service_role; grant execute on function public.employee_attendance_state() to authenticated; grant execute on function public.employee_attendance_state() to service_role;
revoke all on function public.employee_punch_offline(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time_token text, p_token_device_time timestamp with time zone, p_device_time timestamp with time zone, p_monotonic_ms bigint, p_device_now timestamp with time zone) from public, anon, authenticated, service_role; grant execute on function public.employee_punch_offline(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time_token text, p_token_device_time timestamp with time zone, p_device_time timestamp with time zone, p_monotonic_ms bigint, p_device_now timestamp with time zone) to authenticated; grant execute on function public.employee_punch_offline(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time_token text, p_token_device_time timestamp with time zone, p_device_time timestamp with time zone, p_monotonic_ms bigint, p_device_now timestamp with time zone) to service_role;