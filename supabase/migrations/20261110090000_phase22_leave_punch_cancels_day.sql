-- Phase 22: an approved leave no longer sends the punch to review. The first punch of a leave day cancels THAT day of the leave
-- (split like phase 15, the balance comes back by itself), the employee is told, the audit log has it; the admin may restore the day.
--   * private.cancel_leave_days: the shared "cancel some working days of a request" (whole request, shrink, or split).
--   * private.record_punch: a leave the employee asked for -> the day is cancelled and the punch is clean (needs_review untouched by the
--     leave); a company-granted leave day (company_leave_day_id) keeps the phase 15 behaviour. Result: leave_day_cancelled.
--   * employee_attendance_state: + leave_today {request_id, leave_type, end_date} | null (an own leave covers today).
--   * admin_list_leave_day_cancellations / admin_decide_leave_day ('restore_leave' | 'normal_day').
-- Phase 15's admin_resolve_leave_conflict is untouched (rows flagged before this phase still need it). Nothing is deleted.
-- Rollback: *_ROLLBACK.sql (days already cancelled stay cancelled: that is data, not structure).

-- Cancel some working days of an approved leave request and rebuild what remains (the split rule of phase 15, without an admin).
-- p_cancel must be working days inside the request. Everything cancelled = the request is cancelled; otherwise the first remaining part keeps
-- the original request and each later part is a new approved request (same type, finished approvals copied). Returns {whole, ids}.
create or replace function private.cancel_leave_days(p_req public.requests, p_cancel date[], p_tz text, p_text text, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_first date := (p_req.start_at at time zone p_tz)::date;
  v_last date := ((p_req.end_at - interval '1 second') at time zone p_tz)::date;
  v_work date[];
  v_whole boolean;
  v_start date;
  v_cnt numeric;
  v_ids uuid[] := '{}';
  v_new uuid;
  d date;
  i integer;
begin
  select coalesce(array_agg(v_first + g order by g), '{}') into v_work
  from generate_series(0, v_last - v_first) as g
  where private.leave_days(p_req.employee_id, v_first + g, v_first + g) > 0;
  if p_cancel is null or cardinality(p_cancel) = 0 or exists (select 1 from unnest(p_cancel) as y where y is null or not (y = any (v_work))) then
    raise exception 'invalid_days' using errcode = '22023';
  end if;
  v_whole := not exists (select 1 from unnest(v_work) as w where not (w = any (p_cancel)));

  if v_whole then
    update public.request_approvals set status = 'cancelled' where request_id = p_req.id and status in ('waiting', 'pending');
    update public.requests
       set status = 'cancelled', decided_by = p_by, decided_at = now(), decision_note = left(p_text, 500), current_step = null, updated_at = now()
     where id = p_req.id;
    return jsonb_build_object('whole', true, 'ids', jsonb_build_array(p_req.id));
  end if;

  -- The parts: maximal runs of dates that are not cancelled; a run with no working day (only days off) is not a leave.
  for i in 0 .. (v_last - v_first + 1) loop
    d := v_first + i;
    if d <= v_last and not (d = any (p_cancel)) then
      v_start := coalesce(v_start, d);
    elsif v_start is not null then
      v_cnt := private.leave_days(p_req.employee_id, v_start, d - 1);
      if v_cnt > 0 then
        if cardinality(v_ids) = 0 then
          update public.requests
             set start_at = v_start::timestamp at time zone p_tz, end_at = d::timestamp at time zone p_tz, days = v_cnt,
                 charged_days = case when p_req.charged_days is null then null else least(p_req.charged_days, v_cnt) end,
                 decision_note = left(p_text, 500), updated_at = now()
           where id = p_req.id;
          v_ids := array[p_req.id];
        else
          v_new := gen_random_uuid();
          insert into public.requests
          select (jsonb_populate_record(null::public.requests, to_jsonb(p_req) || jsonb_build_object(
            'id', v_new, 'start_at', v_start::timestamp at time zone p_tz, 'end_at', d::timestamp at time zone p_tz, 'days', v_cnt,
            'charged_days', case when p_req.charged_days is null then null else least(p_req.charged_days, v_cnt) end,
            'request_key', null, 'decision_note', left(p_text, 500), 'updated_at', now()))).*;
          insert into public.request_approvals
          select (jsonb_populate_record(null::public.request_approvals, to_jsonb(a) || jsonb_build_object('id', gen_random_uuid(), 'request_id', v_new))).*
          from public.request_approvals a where a.request_id = p_req.id and a.status in ('approved', 'skipped');
          v_ids := v_ids || v_new;
        end if;
      end if;
      v_start := null;
    end if;
  end loop;
  return jsonb_build_object('whole', false, 'ids', to_jsonb(v_ids));
end;
$$;
revoke all on function private.cancel_leave_days(public.requests, date[], text, text, uuid) from public, anon, authenticated;

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

  return jsonb_build_object(
    'employee', jsonb_build_object('full_name', me.full_name, 'employee_number', me.employee_number),
    'company', jsonb_build_object('name', me.company_name, 'timezone', me.timezone),
    'next_action', case when v_open.id is null and not v_forgot then 'check_in' else 'check_out' end,
    'open_session', case when v_open.id is null then null else jsonb_build_object('started_at', v_started) end,
    'can_check_out_without_in', v_can_leave,
    'forgot_check_in', v_forgot,
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

-- The admin's list: days of a leave that a punch cancelled and nobody has decided yet.
create or replace function public.admin_list_leave_day_cancellations(p_limit integer default 100)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, occurred_at timestamptz, day date, leave_type text, request_id uuid)
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select ev.id, ev.employee_id, emp.employee_number, emp.full_name, ev.occurred_at,
         (ev.metadata -> 'leave_day' ->> 'day')::date, ev.metadata -> 'leave_day' ->> 'leave_type', (ev.metadata -> 'leave_day' ->> 'request_id')::uuid
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  where ev.company_id = v_company and ev.metadata ? 'leave_day' and not (ev.metadata ? 'leave_decision')
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 100), 500), 1);
end;
$$;
revoke all on function public.admin_list_leave_day_cancellations(integer) from public, anon;
grant execute on function public.admin_list_leave_day_cancellations(integer) to authenticated;

-- The admin decides about such a day: 'restore_leave' (it was a leave day after all: an approved one-day request again) or
-- 'normal_day' (he worked: the cancellation stands). Either way the row leaves the list.
create or replace function public.admin_decide_leave_day(p_event_id uuid, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_admin uuid := (select auth.uid());
  v_ev public.attendance_events;
  v_req public.requests;
  v_tz text;
  v_day date;
  v_note text := left(nullif(trim(coalesce(p_note, '')), ''), 300);
  v_new uuid;
  v_text text;
begin
  if p_decision is null or p_decision not in ('restore_leave', 'normal_day') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id and ev.company_id = v_company;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  -- Same lock order as record_punch: the employee first, then the event, then the request.
  perform 1 from public.employees e where e.id = v_ev.employee_id for update;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id for update;
  if not (v_ev.metadata ? 'leave_day') then
    raise exception 'not_leave_day_cancelled' using errcode = 'P0001';
  end if;
  if v_ev.metadata ? 'leave_decision' then
    raise exception 'already_resolved' using errcode = 'P0001';
  end if;
  v_day := (v_ev.metadata -> 'leave_day' ->> 'day')::date;

  if p_decision = 'restore_leave' then
    select r.* into v_req from public.requests r
    where r.id = (v_ev.metadata -> 'leave_day' ->> 'request_id')::uuid and r.company_id = v_company for update;
    if not found then
      raise exception 'leave_gone' using errcode = 'P0001';
    end if;
    select c.timezone into v_tz from public.companies c where c.id = v_company;
    if private.approved_leave_on(v_ev.employee_id, v_day) is not null then
      raise exception 'already_on_leave' using errcode = 'P0001';
    end if;
    if private.leave_days(v_ev.employee_id, v_day, v_day) <= 0 then
      raise exception 'not_a_workday' using errcode = 'P0001';
    end if;
    v_text := 'أُعيد يوم ' || to_char(v_day, 'YYYY-MM-DD') || ' إلى إجازتك' || coalesce(' — ' || v_note, '');
    v_new := gen_random_uuid();
    insert into public.requests
    select (jsonb_populate_record(null::public.requests, to_jsonb(v_req) || jsonb_build_object(
      'id', v_new, 'status', 'approved', 'start_at', v_day::timestamp at time zone v_tz, 'end_at', (v_day + 1)::timestamp at time zone v_tz,
      'days', private.leave_days(v_ev.employee_id, v_day, v_day), 'charged_days', null, 'request_key', null, 'current_step', null,
      'decided_by', v_admin, 'decided_at', now(), 'decision_note', left(v_text, 500), 'created_at', now(), 'updated_at', now()))).*;
    insert into public.request_approvals
    select (jsonb_populate_record(null::public.request_approvals, to_jsonb(a) || jsonb_build_object('id', gen_random_uuid(), 'request_id', v_new))).*
    from public.request_approvals a where a.request_id = v_req.id and a.status in ('approved', 'skipped');
    perform private.notify(v_req.employee_id, v_req.company_id, 'request_decided', 'أُعيد يوم إلى إجازتك',
      v_text, '?tab=requests', 'request-' || v_new::text, 86400 * 7);
    perform public.audit_write(v_company, 'leave.day_restored', 'request', v_new::text,
      jsonb_build_object('employee_id', v_ev.employee_id, 'event_id', v_ev.id, 'day', v_day, 'leave_type', v_req.leave_type,
                         'original_request', v_req.id, 'note', v_note));
  else
    perform public.audit_write(v_company, 'leave.day_normal', 'attendance_event', v_ev.id::text,
      jsonb_build_object('employee_id', v_ev.employee_id, 'event_id', v_ev.id, 'day', v_day,
                         'leave_type', v_ev.metadata -> 'leave_day' ->> 'leave_type', 'note', v_note));
  end if;

  update public.attendance_events
     set metadata = metadata || jsonb_build_object('leave_decision', jsonb_build_object(
           'action', p_decision, 'by', v_admin, 'at', now(), 'note', v_note, 'request_id', v_new))
   where id = v_ev.id;
  return jsonb_build_object('event_id', v_ev.id, 'decision', p_decision, 'day', v_day, 'request_id', v_new);
end;
$$;
revoke all on function public.admin_decide_leave_day(uuid, text, text) from public, anon;
grant execute on function public.admin_decide_leave_day(uuid, text, text) to authenticated;
