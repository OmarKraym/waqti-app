-- Phase 25: automatic punch-button mode (companies.auto_punch_mode, ships OFF).
-- The punch button is decided by the server from the employee's own shift, not by the employee:
--   expected = check_out  only when he has an open check-in TODAY (company time) and now >= the flip time;
--   expected = check_in   otherwise (before the flip, after he left, a late arrival, a new day).
--   flip time = the middle of today's shift = start + (end - start) / 2, or the exit time of an approved early-leave
--   permission when that is earlier (so nobody is stuck before the middle when the company already allowed him to leave).
--   The shift day resets at 00:00 company time. The schema allows no overnight shift (schedule_times_check: end_time > start_time).
-- With the switch on, private.record_punch refuses a punch of the other kind ('mode_mismatch'); a check-in left open on a
-- previous day is marked missed_checkout and flagged for review (the phase 8a status: no check-out time is invented) and
-- does not block today's check-in. With the switch off nothing changes: every added line is guarded by it.
-- New (private): flag_stale_open_session, punch_mode, expected_punch_type.
-- New (admin): admin_get_auto_punch_mode, admin_set_auto_punch_mode, admin_punch_mode_preview.
-- Changed: private.record_punch (3 guarded additions), public.employee_attendance_state (keys: punch_mode; next_action,
--   can_check_out_without_in and forgot_check_in follow the mode when it is on).
-- Rollback: 20261115090000_phase25_auto_punch_mode_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision, double precision, timestamp with time zone, jsonb)') is null
     or to_regprocedure('public.employee_attendance_state()') is null
     or to_regprocedure('private.close_missed_checkout(uuid, timestamp with time zone)') is null
     or to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                    where t.typname = 'attendance_session_status' and e.enumlabel = 'missed_checkout') then
    raise exception 'phase25: expected objects are missing (apply phases 8a and 22 first)';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- the switch
alter table public.companies add column auto_punch_mode boolean not null default false;

-- ---------------------------------------------------------------- a check-in left open on a previous day
-- Marks every open session whose check-in is on an earlier company-time day than p_at as missed_checkout and flags its
-- check-in for review (same marks as private.close_missed_checkout). No check-out event is created. Returns true when it marked one.
create or replace function private.flag_stale_open_session(p_employee uuid, p_at timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_day date;
  v_n integer;
begin
  select c.timezone into v_tz from public.employees e join public.companies c on c.id = e.company_id where e.id = p_employee;
  if v_tz is null then return false; end if;
  v_day := (p_at at time zone v_tz)::date;
  with marked as (
    update public.attendance_sessions s set status = 'missed_checkout'
      from public.attendance_events ev
     where ev.id = s.check_in_event_id and s.employee_id = p_employee and s.status = 'open'
       and (ev.occurred_at at time zone v_tz)::date < v_day
    returning s.check_in_event_id)
  update public.attendance_events x
     set needs_review = true, metadata = x.metadata || jsonb_build_object('missed_checkout', true)
   where x.id in (select check_in_event_id from marked);
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
revoke all on function private.flag_stale_open_session(uuid, timestamp with time zone) from public, anon, authenticated;

-- ---------------------------------------------------------------- the rule
create or replace function private.punch_mode(p_employee uuid, p_at timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_day date;
  v_reset timestamptz;      -- 00:00 of the local day
  v_next timestamptz;       -- 00:00 of the next local day: the day resets here
  v_w record;
  v_st timestamptz;
  v_en timestamptz;
  v_mid timestamptz;
  v_exit timestamptz;
  v_flip timestamptz;
  v_open boolean;
  v_stale boolean;
  v_expected text;
  v_reason text;
begin
  select c.timezone into v_tz from public.employees e join public.companies c on c.id = e.company_id where e.id = p_employee;
  if v_tz is null then
    raise exception 'employee_not_found' using errcode = 'P0001';
  end if;
  v_day := (p_at at time zone v_tz)::date;
  v_reset := v_day::timestamp at time zone v_tz;
  v_next := (v_day + 1)::timestamp at time zone v_tz;

  select ws.start_time, ws.end_time into v_w from public.employee_work_schedules ws
  where ws.employee_id = p_employee and ws.weekday = extract(dow from v_day)::int
    and ws.is_workday and ws.start_time is not null and ws.end_time is not null;
  if found then
    v_st := (v_day + v_w.start_time) at time zone v_tz;
    v_en := (v_day + v_w.end_time) at time zone v_tz;
    v_mid := v_st + (v_en - v_st) / 2;
    -- an approved early-leave permission (start_at = the exit time) flips earlier
    select min(r.start_at) into v_exit
    from public.requests r join public.permission_types pt on pt.id = r.permission_type_id and pt.mode = 'early_leave'
    where r.employee_id = p_employee and r.request_type = 'permission' and r.status = 'approved'
      and r.start_at >= v_reset and r.start_at < v_next;
    v_flip := least(v_mid, coalesce(v_exit, v_mid));
  end if;

  select coalesce(bool_or(ev.occurred_at >= v_reset), false), coalesce(bool_or(ev.occurred_at < v_reset), false)
    into v_open, v_stale
  from public.attendance_sessions s join public.attendance_events ev on ev.id = s.check_in_event_id
  where s.employee_id = p_employee and s.status = 'open' and ev.occurred_at <= p_at;

  if v_open and v_flip is null then
    v_expected := 'check_out'; v_reason := 'no_shift';
  elsif v_open and p_at >= v_flip then
    v_expected := 'check_out'; v_reason := 'after_flip';
  elsif v_open then
    v_expected := 'check_in'; v_reason := 'before_flip';
  else
    v_expected := 'check_in'; v_reason := case when v_flip is null then 'no_shift' else 'no_open_check_in' end;
  end if;

  return jsonb_build_object(
    'expected', v_expected, 'reason', v_reason,
    'locked', v_open and v_flip is not null and p_at < v_flip,
    'flips_at', v_flip, 'reset_at', v_next,
    'shift_start', v_st, 'shift_end', v_en, 'midpoint', v_mid,
    'open_session', v_open, 'stale_open', v_stale);
end;
$$;
revoke all on function private.punch_mode(uuid, timestamp with time zone) from public, anon, authenticated;

create or replace function private.expected_punch_type(p_employee uuid, p_at timestamptz)
returns text
language sql
stable
security definer
set search_path = ''
as $$ select private.punch_mode(p_employee, p_at) ->> 'expected' $$;
revoke all on function private.expected_punch_type(uuid, timestamp with time zone) from public, anon, authenticated;

-- ---------------------------------------------------------------- record_punch
create or replace function private.record_punch(p_employee_id uuid, p_policy text, p_outside_action text, p_max_accuracy_m numeric, p_timezone text, p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_time timestamp with time zone, p_meta jsonb)
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
  v_suspect text[] := '{}';
  v_win record;
  v_orphan boolean := false;
  v_last record;
  v_leave uuid;
  v_on_leave boolean := false;
  v_leave_flag boolean := false;
  v_cancel boolean := false;
  v_company_day boolean := false;
  v_ltype text;
  v_day date := (p_time at time zone p_timezone)::date;
  v_req public.requests;
  v_res jsonb;
  v_text text;
  v_auto boolean;
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

  -- Phase 25: automatic punch mode. Only when the company switched it on (companies.auto_punch_mode, default off).
  -- A check-in left open on a previous local day is flagged for review and does not block today (see flag_stale_open_session).
  select c.auto_punch_mode into v_auto from public.employees e join public.companies c on c.id = e.company_id where e.id = p_employee_id;
  if coalesce(v_auto, false) then
    perform private.flag_stale_open_session(p_employee_id, p_time);
  end if;

  -- Real next action (server state), compared with what the employee saw.
  select s.id into v_open_id from public.attendance_sessions s
  where s.employee_id = p_employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  v_action := case when v_open_id is null then 'check_in' else 'check_out' end;
  -- Phase 25: with the automatic mode on, the server decides what the button is (the middle of the shift, reset at 00:00).
  -- A punch of the other kind is refused, so the rule cannot be bypassed by calling the function directly.
  if coalesce(v_auto, false) and p_expected_action <> private.expected_punch_type(p_employee_id, p_time) then
    raise exception 'mode_mismatch' using errcode = 'P0001';
  end if;
  -- Phase 13: no open session but the employee asks for a check-out = he forgot to check in. Allowed, flagged for review,
  -- and no session is touched. Refused if his latest punch is already a check-out on the same day (nothing to leave from).
  if v_open_id is null and p_expected_action = 'check_out' then
    select x.event_type, x.occurred_at into v_last from public.attendance_events x
    where x.employee_id = p_employee_id order by x.occurred_at desc, x.id desc limit 1;
    if found and v_last.event_type = 'check_out'
       and (v_last.occurred_at at time zone p_timezone)::date = (p_time at time zone p_timezone)::date then
      raise exception 'state_changed' using errcode = 'P0001';
    end if;
    v_action := 'check_out';
    v_orphan := true;
    v_suspect := array_append(v_suspect, 'missing_checkin');
    v_review := true;
  end if;
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

  -- Phase 22: an approved leave covers this working day. The punch is never blocked. Only the first punch of the local day counts
  -- (an earlier one that carries 'leave_day' - cancelled, or restored by the admin - or the old flag settles the day).
  --   * a leave the employee asked for: the punch is NOT sent to review; that day of the leave is cancelled after the insert (below),
  --     the employee is told, and the admin may restore the day (admin_decide_leave_day).
  --   * a leave the company granted (a holiday, company_leave_day_id): unchanged from phase 15 - flagged for the admin.
  v_leave := private.approved_leave_on(p_employee_id, v_day);
  if v_leave is not null then
    v_on_leave := true;
    if not exists (select 1 from public.attendance_events x
                   where x.employee_id = p_employee_id
                     and (x.occurred_at at time zone p_timezone)::date = v_day
                     and (x.metadata -> 'suspect' ? 'on_approved_leave' or x.metadata ? 'leave_day')) then
      select r.leave_type, r.company_leave_day_id is not null into v_ltype, v_company_day from public.requests r where r.id = v_leave;
      if v_company_day then
        v_suspect := array_append(v_suspect, 'on_approved_leave');
        v_review := true;
        v_leave_flag := true;
      else
        v_cancel := true;
      end if;
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
    coalesce(p_meta ->> 'auth_method', 'password'), p_request_id, v_status, v_review, p_policy,
    jsonb_build_object('geofence_enforced', p_policy = 'geofence', 'reading', p_reading,
                       'outside_action', p_outside_action)
      || case when cardinality(v_suspect) > 0 then jsonb_build_object('suspect', to_jsonb(v_suspect)) else '{}'::jsonb end
      || case when v_leave_flag then jsonb_build_object('leave_request_id', v_leave) else '{}'::jsonb end
      || case when v_cancel then jsonb_build_object('leave_day', jsonb_build_object('request_id', v_leave, 'leave_type', v_ltype, 'day', v_day)) else '{}'::jsonb end
      || (coalesce(p_meta, '{}'::jsonb) - 'auth_method' - 'review')
  ) returning id into v_event_id;

  if v_orphan then
    null;  -- a check-out without a check-in: there is no session to close
  elsif v_action = 'check_in' then
    insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status)
    values (p_employee_id, (p_time at time zone p_timezone)::date, v_event_id, 'open');
  else
    update public.attendance_sessions set check_out_event_id = v_event_id, status = 'closed'
    where id = v_open_id;
  end if;

  -- Phase 22: cancel that one day of the leave (the split logic of phase 15, no admin involved), tell the employee, write the audit row.
  if v_cancel then
    select r.* into v_req from public.requests r where r.id = v_leave for update;
    if found then
      v_text := 'أُلغي يوم ' || to_char(v_day, 'YYYY-MM-DD') || ' من إجازتك لأنك بصمت فيه';
      v_res := private.cancel_leave_days(v_req, array[v_day], p_timezone, v_text, null);
      perform private.notify(v_req.employee_id, v_req.company_id, 'request_decided',
        case when (v_res ->> 'whole')::boolean then 'أُلغيت إجازتك' else 'أُلغي يوم من إجازتك' end,
        case when (v_res ->> 'whole')::boolean then private.request_summary(v_req.id) || chr(10) || v_text else v_text end,
        '?tab=requests', 'request-' || v_req.id::text, 86400 * 7);
      perform public.audit_write(v_req.company_id, 'leave.cancelled_by_punch', 'request', v_req.id::text,
        jsonb_build_object('employee_id', v_req.employee_id, 'event_id', v_event_id, 'day', v_day, 'leave_type', v_req.leave_type,
                           'whole', (v_res ->> 'whole')::boolean, 'previous_note', v_req.decision_note, 'requests', v_res -> 'ids'));
    else
      v_cancel := false;
    end if;
  end if;

  return jsonb_build_object(
    'event_id', v_event_id, 'action', v_action, 'server_time', p_time,
    'location_status', v_status, 'needs_review', v_review, 'duplicate', false, 'missing_checkin', v_orphan,
    'on_approved_leave', v_on_leave, 'leave_day_cancelled', v_cancel);
end;
$function$;


-- ---------------------------------------------------------------- employee_attendance_state
create or replace function public.employee_attendance_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me record;
  v_open public.attendance_sessions;
  v_started timestamptz;
  v_now timestamptz := now();
  v_win record;
  v_last record;
  v_can_leave boolean := false;
  v_in_win record;
  v_forgot boolean := false;
  v_auto boolean;
  v_mode jsonb;
begin
  select * into me from public.require_active_employee();
  perform private.close_missed_checkout(me.employee_id, v_now);
  -- Phase 25: automatic punch mode (off unless the company turned it on).
  select c.auto_punch_mode into v_auto from public.companies c where c.id = me.company_id;
  v_auto := coalesce(v_auto, false);
  if v_auto then
    perform private.flag_stale_open_session(me.employee_id, v_now);
  end if;

  select * into v_open from public.attendance_sessions s
  where s.employee_id = me.employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  if found then
    select ev.occurred_at into v_started from public.attendance_events ev where ev.id = v_open.check_in_event_id;
  end if;
  select * into v_win from private.punch_window(me.employee_id, case when v_open.id is null then 'check_in' else 'check_out' end, v_now);
  v_in_win := v_win;

  -- Phase 13: may he record a check-out although he has no check-in (forgot it)? Only inside the check-out window,
  -- and not when his latest punch is already a check-out today.
  if v_open.id is null then
    select x.event_type, x.occurred_at into v_last from public.attendance_events x
    where x.employee_id = me.employee_id order by x.occurred_at desc, x.id desc limit 1;
    v_can_leave := not (found and v_last.event_type = 'check_out'
                        and (v_last.occurred_at at time zone me.timezone)::date = (v_now at time zone me.timezone)::date)
                   and (select w.allowed from private.punch_window(me.employee_id, 'check_out', v_now) w);
    -- Phase 14: the check-in window is over (or not open) while the check-out window is open: he forgot to check in, so the
    -- main button becomes "check out" (the reason of the check-in window is not used: with a night shift it can be 'too_early').
    if v_can_leave and not v_in_win.allowed then
      v_forgot := true;
      select * into v_win from private.punch_window(me.employee_id, 'check_out', v_now);
    end if;
  end if;

  if v_auto then
    v_mode := private.punch_mode(me.employee_id, v_now);
  end if;

  return jsonb_build_object(
    'employee', jsonb_build_object('full_name', me.full_name, 'employee_number', me.employee_number),
    'company', jsonb_build_object('name', me.company_name, 'timezone', me.timezone),
    'next_action', case when v_auto then v_mode ->> 'expected'
                        when v_open.id is null and not v_forgot then 'check_in' else 'check_out' end,
    'open_session', case when v_open.id is null then null else jsonb_build_object('started_at', v_started) end,
    'can_check_out_without_in', v_can_leave and not v_auto,
    'forgot_check_in', v_forgot and not v_auto,
    -- Phase 25: what the button is right now. locked = checked in, and the check-out opens at flips_at.
    'punch_mode', case when v_auto
                       then jsonb_build_object('auto', true, 'expected', v_mode ->> 'expected', 'locked', (v_mode ->> 'locked')::boolean,
                                               'flips_at', v_mode -> 'flips_at', 'reset_at', v_mode -> 'reset_at')
                       else jsonb_build_object('auto', false, 'locked', false) end,
    -- Phase 22: an approved leave he asked for covers today (a punch today cancels this day of it). null = none.
    'leave_today', (select jsonb_build_object('request_id', r.id, 'leave_type', r.leave_type,
                                              'end_date', ((r.end_at - interval '1 second') at time zone me.timezone)::date)
                    from public.requests r
                    where r.id = private.approved_leave_on(me.employee_id, (v_now at time zone me.timezone)::date)
                      and r.company_leave_day_id is null),
    'location_policy', me.location_policy,
    'outside_action', me.outside_action,
    'max_accuracy_m', me.max_accuracy_m,
    'biometric', jsonb_build_object('policy', (select c.biometric_policy from public.companies c where c.id = me.company_id),
                                    'has_device', exists (select 1 from public.webauthn_credentials w where w.employee_id = me.employee_id),
                                    'login_enabled', coalesce((select w.login_enabled from public.webauthn_credentials w where w.employee_id = me.employee_id), false)),
    'punch_window', jsonb_build_object('allowed', v_win.allowed, 'opens_at', v_win.opens_at,
                                       'closes_at', v_win.closes_at, 'reason', v_win.reason),
    'recent_events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ev.id, 'action', ev.event_type, 'server_time', ev.occurred_at,
               'location_status', public.event_location_status(ev), 'needs_review', ev.needs_review,
               'by_admin', coalesce(ev.authentication_method = 'admin', false))
             order by ev.occurred_at desc)
      from (select * from public.attendance_events x
            where x.employee_id = me.employee_id
            order by x.occurred_at desc limit 10) ev
    ), '[]'::jsonb),
    'server_time', v_now,
    'time_token', private.issue_time_token(me.employee_id, v_now)
  );
end;
$function$;


-- ---------------------------------------------------------------- admin: the switch and a preview
create or replace function public.admin_get_auto_punch_mode()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return (select jsonb_build_object('enabled', c.auto_punch_mode) from public.companies c where c.id = v_company);
end;
$$;
revoke all on function public.admin_get_auto_punch_mode() from public, anon;
grant execute on function public.admin_get_auto_punch_mode() to authenticated;

create or replace function public.admin_set_auto_punch_mode(p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_enabled is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  update public.companies set auto_punch_mode = p_enabled, updated_at = now() where id = v_company;
  perform public.audit_write(v_company, 'company.auto_punch_mode', 'company', v_company::text, jsonb_build_object('enabled', p_enabled));
  return jsonb_build_object('enabled', p_enabled);
end;
$$;
revoke all on function public.admin_set_auto_punch_mode(boolean) from public, anon;
grant execute on function public.admin_set_auto_punch_mode(boolean) to authenticated;

-- What the button of one employee is at p_at (default: now): the flip time, the reset time and the mode, from his saved shift.
create or replace function public.admin_punch_mode_preview(p_employee_id uuid, p_at timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if not exists (select 1 from public.employees e where e.id = p_employee_id and e.company_id = v_company) then
    raise exception 'employee_not_found' using errcode = 'P0001';
  end if;
  return private.punch_mode(p_employee_id, coalesce(p_at, now()));
end;
$$;
revoke all on function public.admin_punch_mode_preview(uuid, timestamp with time zone) from public, anon;
grant execute on function public.admin_punch_mode_preview(uuid, timestamp with time zone) to authenticated;
