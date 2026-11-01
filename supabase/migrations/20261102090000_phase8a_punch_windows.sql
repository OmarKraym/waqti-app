-- Phase 8a: punch windows (spec docs/superpowers/specs/2026-11-01-biometric-punch-windows-design.md, section 3).
-- The admin limits WHEN employees may punch, around each employee's shift (company values, per-employee overrides).
-- An active overtime assignment opens its own window. A missed check-out window closes the session as
-- "missed_checkout" (no time is invented) and flags it for review. Everything ships OFF.
-- Also adds companies.biometric_policy (used by phase 8b) so both settings are saved by one function.
-- Rollback: 20261102090000_phase8a_punch_windows_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision, double precision, timestamp with time zone, jsonb)') is null
     or to_regprocedure('public.employee_attendance_state()') is null
     or to_regprocedure('private.overtime_actual(uuid, timestamp with time zone, timestamp with time zone)') is null then
    raise exception 'phase8a: expected functions are missing';
  end if;
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                 where t.typname = 'attendance_session_status' and e.enumlabel = 'missed_checkout') then
    raise exception 'phase8a: run 20261102085900_phase8a_enum.sql first';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- settings
alter table public.companies
  add column biometric_policy text not null default 'off' check (biometric_policy in ('off', 'required')),
  add column punch_windows_enabled boolean not null default false,
  add column in_before_min smallint not null default 60 check (in_before_min between 0 and 720),
  add column in_after_min smallint not null default 120 check (in_after_min between 0 and 720),
  add column out_before_min smallint not null default 120 check (out_before_min between 0 and 720),
  add column out_after_min smallint not null default 60 check (out_after_min between 0 and 720);

alter table public.employees
  add column in_before_min smallint check (in_before_min between 0 and 720),
  add column in_after_min smallint check (in_after_min between 0 and 720),
  add column out_before_min smallint check (out_before_min between 0 and 720),
  add column out_after_min smallint check (out_after_min between 0 and 720);

alter table public.attendance_sessions drop constraint attendance_sessions_status_check;
alter table public.attendance_sessions add constraint attendance_sessions_status_check check (
  (status = 'open' and check_out_event_id is null)
  or (status = 'closed' and check_out_event_id is not null)
  or (status = 'missed_checkout' and check_out_event_id is null));

-- ---------------------------------------------------------------- the window rule
-- The windows for one action, built from the shifts of p_from..p_to (a shift whose end_time <= start_time ends the
-- next day) and every assigned overtime that overlaps those days. check_in: [start - in_before, start + in_after];
-- check_out: [end - out_before, end + out_after]. Employee values override the company's.
create or replace function private.punch_windows_list(p_employee uuid, p_action text, p_from date, p_to date)
returns table(lo timestamptz, hi timestamptz, kind text)
language sql
stable
security definer
set search_path = ''
as $$
  with cfg as (
    select c.timezone as tz,
           coalesce(e.in_before_min, c.in_before_min) as ib, coalesce(e.in_after_min, c.in_after_min) as ia,
           coalesce(e.out_before_min, c.out_before_min) as ob, coalesce(e.out_after_min, c.out_after_min) as oa
    from public.employees e join public.companies c on c.id = e.company_id where e.id = p_employee),
  periods as (
    select (x.d + w.start_time) at time zone cfg.tz as st,
           (x.d + w.end_time + case when w.end_time <= w.start_time then interval '1 day' else interval '0' end) at time zone cfg.tz as en,
           'shift'::text as kind
    from cfg cross join generate_series(p_from, p_to, interval '1 day') g(dd)
    cross join lateral (select g.dd::date as d) x
    join public.employee_work_schedules w
      on w.employee_id = p_employee and w.weekday = extract(dow from x.d)::int
     and w.is_workday and w.start_time is not null and w.end_time is not null
    union all
    select o.start_at, o.end_at, 'overtime'
    from cfg cross join public.overtime_assignments o
    where o.employee_id = p_employee and o.status = 'assigned'
      and o.end_at > (p_from::timestamp at time zone cfg.tz) - interval '1 day'
      and o.start_at < ((p_to + 1)::timestamp at time zone cfg.tz) + interval '1 day')
  select case when p_action = 'check_in' then p.st - make_interval(mins => cfg.ib) else p.en - make_interval(mins => cfg.ob) end,
         case when p_action = 'check_in' then p.st + make_interval(mins => cfg.ia) else p.en + make_interval(mins => cfg.oa) end,
         p.kind
  from periods p cross join cfg
  union all
  -- An approved early-leave permission (start_at = the exit time, end_at = the shift end): the check-out window opens
  -- ob minutes before the exit time and lasts until the shift end + oa. An approved late-arrival permission
  -- (start_at = the shift start, end_at = the arrival time): the check-in window lasts until the arrival time + ia.
  select r.start_at - make_interval(mins => cfg.ob), r.end_at + make_interval(mins => cfg.oa), 'shift'::text
  from cfg join public.requests r on r.employee_id = p_employee and r.request_type = 'permission' and r.status = 'approved'
  join public.permission_types pt on pt.id = r.permission_type_id and pt.mode = 'early_leave'
  where p_action = 'check_out'
    and r.end_at > (p_from::timestamp at time zone cfg.tz) - interval '1 day'
    and r.start_at < ((p_to + 1)::timestamp at time zone cfg.tz) + interval '1 day'
  union all
  select r.start_at - make_interval(mins => cfg.ib), r.end_at + make_interval(mins => cfg.ia), 'shift'::text
  from cfg join public.requests r on r.employee_id = p_employee and r.request_type = 'permission' and r.status = 'approved'
  join public.permission_types pt on pt.id = r.permission_type_id and pt.mode = 'late_arrival'
  where p_action = 'check_in'
    and r.end_at > (p_from::timestamp at time zone cfg.tz) - interval '1 day'
    and r.start_at < ((p_to + 1)::timestamp at time zone cfg.tz) + interval '1 day'
$$;
revoke all on function private.punch_windows_list(uuid, text, date, date) from public, anon, authenticated;

-- Off, or no schedule at all -> no limits. Inside a window -> allowed ('shift' or 'overtime'). Otherwise the next
-- window that opens later the same local day ('too_early'), else 'too_late' (a working day) or 'day_off'.
create or replace function private.punch_window(p_employee uuid, p_action text, p_at timestamptz)
returns table(allowed boolean, opens_at timestamptz, closes_at timestamptz, reason text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_on boolean; v_tz text; v_today date; v_hit text; v_next record; v_work_today boolean;
begin
  select c.punch_windows_enabled, c.timezone into v_on, v_tz
  from public.employees e join public.companies c on c.id = e.company_id where e.id = p_employee;
  if not found or not v_on
     or not exists (select 1 from public.employee_work_schedules w where w.employee_id = p_employee) then
    return query select true, null::timestamptz, null::timestamptz, 'no_limits'::text;
    return;
  end if;
  v_today := (p_at at time zone v_tz)::date;

  select t.kind into v_hit from private.punch_windows_list(p_employee, p_action, v_today - 1, v_today + 1) t
  where p_at between t.lo and t.hi order by (t.kind = 'shift') desc limit 1;
  if v_hit is not null then
    return query select true, null::timestamptz, null::timestamptz, v_hit;
    return;
  end if;

  select t.lo, t.hi into v_next from private.punch_windows_list(p_employee, p_action, v_today - 1, v_today + 1) t
  where t.lo > p_at and (t.lo at time zone v_tz)::date = v_today order by t.lo limit 1;
  if found then
    return query select false, v_next.lo, v_next.hi, 'too_early'::text;
    return;
  end if;

  v_work_today := exists (select 1 from public.employee_work_schedules w
                          where w.employee_id = p_employee and w.weekday = extract(dow from v_today)::int and w.is_workday)
               or exists (select 1 from public.overtime_assignments o
                          where o.employee_id = p_employee and o.status = 'assigned'
                            and (o.start_at at time zone v_tz)::date = v_today);
  return query select false, null::timestamptz, null::timestamptz, case when v_work_today then 'too_late' else 'day_off' end;
end;
$$;
revoke all on function private.punch_window(uuid, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- missed check-out
-- The session's check-out window = the first check-out window that ends after the check-in, extended by any
-- check-out window that is already open when it ends (shift + overtime). When it has closed
-- (or, with no such window, 24 hours after the check-in), the session is closed without a check-out and its check-in
-- is flagged for review. Only while windows are on. Returns true when it closed one.
create or replace function private.close_missed_checkout(p_employee uuid, p_at timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sess record; v_in timestamptz; v_tz text; v_on boolean; v_day date; v_close timestamptz; v_next timestamptz;
begin
  select c.punch_windows_enabled, c.timezone into v_on, v_tz
  from public.employees e join public.companies c on c.id = e.company_id where e.id = p_employee;
  if not coalesce(v_on, false)
     or not exists (select 1 from public.employee_work_schedules w where w.employee_id = p_employee) then
    return false;
  end if;
  select s.id, s.check_in_event_id into v_sess from public.attendance_sessions s
  where s.employee_id = p_employee and s.status = 'open' order by s.created_at desc limit 1;
  if not found then return false; end if;
  select ev.occurred_at into v_in from public.attendance_events ev where ev.id = v_sess.check_in_event_id;
  v_day := (v_in at time zone v_tz)::date;

  select t.hi into v_close from private.punch_windows_list(p_employee, 'check_out', v_day - 1, v_day + 1) t
  where t.hi > v_in and t.lo < v_in + interval '24 hours' order by t.hi limit 1;
  v_close := coalesce(v_close, v_in + interval '24 hours');
  -- A check-out window that is open at the moment the session's own window ends (overtime right after the shift)
  -- extends the session: keep following windows that start before the current end and finish after it.
  loop
    select max(t.hi) into v_next from private.punch_windows_list(p_employee, 'check_out', v_day - 1, v_day + 1) t
    where t.lo <= v_close and t.hi > v_close;
    exit when v_next is null;
    v_close := v_next;
  end loop;
  if p_at <= v_close then return false; end if;

  update public.attendance_sessions set status = 'missed_checkout' where id = v_sess.id and status = 'open';
  if not found then return false; end if;
  update public.attendance_events
     set needs_review = true, metadata = metadata || jsonb_build_object('missed_checkout', true)
   where id = v_sess.check_in_event_id;
  return true;
end;
$$;
revoke all on function private.close_missed_checkout(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- the punch (security_fixes_r1 version + windows)
create or replace function private.record_punch(p_employee_id uuid, p_policy text, p_outside_action text, p_max_accuracy_m numeric,
  p_timezone text, p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_time timestamp with time zone, p_meta jsonb)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
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
  v_suspect text[] := '{}';
  v_win record;
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

  -- Phase 8a: a session whose check-out time has passed is closed as missed, so the next action is check-in.
  perform private.close_missed_checkout(p_employee_id, p_time);

  -- Real next action (server state), compared with what the employee saw.
  select s.id into v_open_id from public.attendance_sessions s
  where s.employee_id = p_employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  v_action := case when v_open_id is null then 'check_in' else 'check_out' end;
  if v_action::text <> p_expected_action then
    raise exception 'state_changed' using errcode = 'P0001';
  end if;

  -- Phase 8a: only inside an allowed window (the server's time decides).
  select * into v_win from private.punch_window(p_employee_id, v_action::text, p_time);
  if not v_win.allowed then
    raise exception '%', case when v_win.reason = 'day_off' then 'day_off' else 'outside_punch_window' end
      using errcode = 'P0001', detail = coalesce(v_win.opens_at::text, '') || '|' || coalesce(v_win.closes_at::text, '');
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
    -- SEC-003: signs of a typed or faked position.
    if p_accuracy_m < 3 then
      v_suspect := array_append(v_suspect, 'perfect_accuracy');
    end if;
    if exists (select 1 from public.attendance_events e
               where e.employee_id = p_employee_id and e.location is not null
                 and e.occurred_at > p_time - interval '60 days'
                 and round(extensions.st_y(e.location::extensions.geometry)::numeric, 7) = round(p_lat::numeric, 7)
                 and round(extensions.st_x(e.location::extensions.geometry)::numeric, 7) = round(p_lng::numeric, 7)) then
      v_suspect := array_append(v_suspect, 'same_point');
    end if;
    if cardinality(v_suspect) > 0 then
      v_review := true;
    end if;
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

  -- Phase 8b passes a review flag (e.g. punch without fingerprint) in p_meta.
  if coalesce((p_meta ->> 'review')::boolean, false) then
    v_review := true;
  end if;

  insert into public.attendance_events (
    employee_id, event_type, occurred_at, location, accuracy_meters,
    geofence_id, distance_from_geofence_meters, within_geofence,
    authentication_method, request_id, location_status, needs_review, location_policy, metadata
  ) values (
    p_employee_id, v_action, p_time, v_point, case when v_has_point then round(p_accuracy_m::numeric, 2) end,
    v_geofence.id, v_distance,
    case when p_policy = 'geofence' then v_status = 'inside' else true end,
    coalesce(p_meta ->> 'auth_method', 'password'), p_request_id, v_status, v_review, p_policy,
    jsonb_build_object('geofence_enforced', p_policy = 'geofence', 'reading', p_reading,
                       'outside_action', p_outside_action)
      || case when cardinality(v_suspect) > 0 then jsonb_build_object('suspect', to_jsonb(v_suspect)) else '{}'::jsonb end
      || (coalesce(p_meta, '{}'::jsonb) - 'auth_method' - 'review')
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
$$;
revoke all on function private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision,
  double precision, timestamp with time zone, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- the app's state (now VOLATILE: it may close a missed session)
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

-- ---------------------------------------------------------------- worked overtime ignores sessions without a check-out
create or replace function private.overtime_actual(p_employee uuid, p_start timestamptz, p_end timestamptz)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(floor(sum(extract(epoch from (least(p_end, coalesce(eo.occurred_at, now())) - greatest(p_start, ei.occurred_at)))) / 60), 0)::int
  from public.attendance_sessions s
  join public.attendance_events ei on ei.id = s.check_in_event_id
  left join public.attendance_events eo on eo.id = s.check_out_event_id
  where s.employee_id = p_employee
    and s.status <> 'missed_checkout'
    and ei.occurred_at < p_end
    and coalesce(eo.occurred_at, now()) > p_start
    and least(p_end, coalesce(eo.occurred_at, now())) > greatest(p_start, ei.occurred_at)
$$;
revoke all on function private.overtime_actual(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_get_punch_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return (select jsonb_build_object('biometric_policy', c.biometric_policy, 'punch_windows_enabled', c.punch_windows_enabled,
            'in_before_min', c.in_before_min, 'in_after_min', c.in_after_min,
            'out_before_min', c.out_before_min, 'out_after_min', c.out_after_min)
          from public.companies c where c.id = v_company);
end;
$$;

create or replace function public.admin_set_punch_settings(p_biometric_policy text, p_windows_enabled boolean,
  p_in_before integer, p_in_after integer, p_out_before integer, p_out_after integer)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_biometric_policy is null or p_biometric_policy not in ('off', 'required') or p_windows_enabled is null
     or p_in_before is null or p_in_after is null or p_out_before is null or p_out_after is null
     or least(p_in_before, p_in_after, p_out_before, p_out_after) < 0
     or greatest(p_in_before, p_in_after, p_out_before, p_out_after) > 720 then
    raise exception 'invalid_punch_settings' using errcode = '22023';
  end if;
  update public.companies set biometric_policy = p_biometric_policy, punch_windows_enabled = p_windows_enabled,
         in_before_min = p_in_before, in_after_min = p_in_after, out_before_min = p_out_before, out_after_min = p_out_after
   where id = v_company;
  perform public.audit_write(v_company, 'company.punch_settings', 'company', v_company::text,
    jsonb_build_object('biometric_policy', p_biometric_policy, 'punch_windows_enabled', p_windows_enabled,
      'in_before_min', p_in_before, 'in_after_min', p_in_after, 'out_before_min', p_out_before, 'out_after_min', p_out_after));
  return public.admin_get_punch_settings();
end;
$$;

create or replace function public.admin_set_employee_punch_windows(p_employee_id uuid, p_in_before integer, p_in_after integer,
  p_out_before integer, p_out_after integer)
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
  if coalesce(least(p_in_before, p_in_after, p_out_before, p_out_after), 0) < 0
     or coalesce(greatest(p_in_before, p_in_after, p_out_before, p_out_after), 0) > 720 then
    raise exception 'invalid_punch_settings' using errcode = '22023';
  end if;
  update public.employees set in_before_min = p_in_before, in_after_min = p_in_after,
         out_before_min = p_out_before, out_after_min = p_out_after
   where id = p_employee_id and company_id = v_company;
  perform public.audit_write(v_company, 'employee.punch_windows', 'employee', p_employee_id::text,
    jsonb_build_object('in_before_min', p_in_before, 'in_after_min', p_in_after, 'out_before_min', p_out_before, 'out_after_min', p_out_after));
  return jsonb_build_object('in_before_min', p_in_before, 'in_after_min', p_in_after,
                            'out_before_min', p_out_before, 'out_after_min', p_out_after);
end;
$$;

do $grants$
declare f text;
begin
  foreach f in array array[
    'public.admin_get_punch_settings()',
    'public.admin_set_punch_settings(text, boolean, integer, integer, integer, integer)',
    'public.admin_set_employee_punch_windows(uuid, integer, integer, integer, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$grants$;

-- the employee profile shows the overrides (null = company value)
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
