-- Phase 15: a punch on a day covered by an approved leave is saved but flagged ('on_approved_leave'); the admin keeps the leave or
-- cancels it (the balance returns by itself: it is derived from approved requests; the employee gets a notification and the reason).
--   * private.approved_leave_on(employee, date): the approved leave covering that working day (null if none).
--   * private.record_punch: phase 13 text + the leave check (first punch of the local day is flagged, all punches are saved).
--   * public.admin_review_queue: now also returns `leave` (jsonb) for those events.
--   * public.admin_resolve_leave_conflict(event, 'cancel_leave' | 'keep_leave', note).
-- Rollback: 20261102170000_phase15_leave_conflict_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision, double precision, timestamp with time zone, jsonb)') is null
     or to_regprocedure('public.admin_review_queue(integer)') is null
     or to_regprocedure('public.admin_resolve_review(uuid, text, timestamp with time zone, text)') is null
     or to_regprocedure('private.leave_days(uuid, date, date)') is null
     or to_regprocedure('private.notify(uuid, uuid, text, text, text, text, text, integer)') is null
     or to_regprocedure('private.request_summary(uuid)') is null then
    raise exception 'phase15: expected functions are missing (phases 4, 5, 13 and 14 must be applied first)';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- helpers (private: not callable through the API)
-- The approved leave that covers a WORKING day of the employee (a day off inside the range is not a conflict).
-- The request stores [start of the first day, start of the day after the last day) in the company time zone.
create or replace function private.approved_leave_on(p_employee uuid, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select r.id
  from public.requests r
  join public.companies c on c.id = r.company_id
  where r.employee_id = p_employee and r.request_type = 'leave' and r.status = 'approved'
    and (r.start_at at time zone c.timezone)::date <= p_date
    and ((r.end_at - interval '1 second') at time zone c.timezone)::date >= p_date
    and private.leave_days(p_employee, p_date, p_date) > 0
  order by r.start_at, r.id
  limit 1
$$;
revoke all on function private.approved_leave_on(uuid, date) from public, anon, authenticated;

-- True when the leave is the ONLY reason an event needs a look (location fine, no other suspicion, no offline / missed-checkout /
-- unsupported-fingerprint mark): such an event is cleared together with the leave it conflicted with.
create or replace function private.review_only_leave(p_location_status text, p_metadata jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_location_status, 'not_requested') in ('inside', 'not_requested', 'recorded')
     and not coalesce((p_metadata ->> 'offline')::boolean, false)
     and not coalesce((p_metadata ->> 'missed_checkout')::boolean, false)
     and coalesce(p_metadata ->> 'biometric', '') <> 'unsupported'
     and not exists (select 1 from jsonb_array_elements_text(coalesce(p_metadata -> 'suspect', '[]'::jsonb)) as x(v)
                     where x.v <> 'on_approved_leave')
$$;
revoke all on function private.review_only_leave(text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- the punch (phase 13 text + the leave check)
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
  v_orphan boolean := false;
  v_last record;
  v_leave uuid;
  v_on_leave boolean := false;
  v_leave_flag boolean := false;
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

  -- Phase 15: an approved leave covers this working day. The punch is never blocked: it is saved and flagged for the admin,
  -- who keeps or cancels the leave. Only the first punch of the local day is flagged (the check-out is not a second item).
  v_leave := private.approved_leave_on(p_employee_id, (p_time at time zone p_timezone)::date);
  if v_leave is not null then
    v_on_leave := true;
    if not exists (select 1 from public.attendance_events x
                   where x.employee_id = p_employee_id
                     and (x.occurred_at at time zone p_timezone)::date = (p_time at time zone p_timezone)::date
                     and x.metadata -> 'suspect' ? 'on_approved_leave') then
      v_suspect := array_append(v_suspect, 'on_approved_leave');
      v_review := true;
      v_leave_flag := true;
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

  return jsonb_build_object(
    'event_id', v_event_id, 'action', v_action, 'server_time', p_time,
    'location_status', v_status, 'needs_review', v_review, 'duplicate', false, 'missing_checkin', v_orphan,
    'on_approved_leave', v_on_leave);
end;
$$;
revoke all on function private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision,
  double precision, timestamp with time zone, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin: the queue now says which leave a punch conflicts with
drop function if exists public.admin_review_queue(integer);
create function public.admin_review_queue(p_limit integer default 200)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, event_type public.attendance_event_type,
  occurred_at timestamp with time zone, location_status text, suspect text[], biometric text, missed_checkout boolean,
  offline boolean, sync_delay_s integer, needs_review boolean, review_total bigint, leave jsonb)
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select ev.id, ev.employee_id, emp.employee_number, emp.full_name, ev.event_type, ev.occurred_at, ev.location_status,
         coalesce(array(select jsonb_array_elements_text(ev.metadata -> 'suspect')), '{}'::text[]),
         ev.metadata ->> 'biometric',
         coalesce((ev.metadata ->> 'missed_checkout')::boolean, false),
         coalesce((ev.metadata ->> 'offline')::boolean, false),
         (ev.metadata ->> 'sync_delay_s')::integer,
         ev.needs_review,
         count(*) over (),
         case when ev.metadata ? 'leave_request_id' then
           (select jsonb_build_object('request_id', r.id, 'leave_type', r.leave_type, 'status', r.status, 'days', r.days,
                                      'start_date', (r.start_at at time zone c.timezone)::date,
                                      'end_date', ((r.end_at - interval '1 second') at time zone c.timezone)::date)
            from public.requests r join public.companies c on c.id = r.company_id
            where r.id = (ev.metadata ->> 'leave_request_id')::uuid and r.company_id = v_company)
         end
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  where ev.company_id = v_company and ev.needs_review
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 200), 1000), 1);
end;
$$;
revoke all on function public.admin_review_queue(integer) from public, anon;
grant execute on function public.admin_review_queue(integer) to authenticated;

-- ---------------------------------------------------------------- admin: decide
-- keep_leave: the punch stays recorded, the leave stays approved (this day only).
-- cancel_leave: the WHOLE leave becomes cancelled (no partial shortening): the balance returns by itself, the employee is told, the other
--   days of this leave that were flagged only because of it are cleared. Waiting / pending approval rows are cancelled; finished ones stay.
create or replace function public.admin_resolve_leave_conflict(p_event_id uuid, p_decision text, p_note text default null)
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
  v_review jsonb;
  v_note text := left(nullif(trim(coalesce(p_note, '')), ''), 300);
  v_text text;
  v_cancelled boolean := false;
begin
  if p_decision is null or p_decision not in ('cancel_leave', 'keep_leave') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id and ev.company_id = v_company;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  -- Same lock order as record_punch: the employee first, then the event, then the request.
  perform 1 from public.employees e where e.id = v_ev.employee_id for update;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id for update;
  if not v_ev.needs_review then
    raise exception 'already_resolved' using errcode = 'P0001';
  end if;
  if not coalesce(v_ev.metadata -> 'suspect' ? 'on_approved_leave', false) or not (v_ev.metadata ? 'leave_request_id') then
    raise exception 'not_leave_conflict' using errcode = 'P0001';
  end if;
  select r.* into v_req from public.requests r
  where r.id = (v_ev.metadata ->> 'leave_request_id')::uuid and r.company_id = v_company for update;
  if not found then
    raise exception 'not_leave_conflict' using errcode = 'P0001';
  end if;
  select c.timezone into v_tz from public.companies c where c.id = v_company;
  v_day := (v_ev.occurred_at at time zone v_tz)::date;
  v_review := jsonb_build_object('action', p_decision, 'by', v_admin, 'at', now(), 'note', v_note);

  if p_decision = 'cancel_leave' and v_req.status = 'approved' then
    v_text := 'أُلغيت إجازتك بسبب تسجيل حضورك يوم ' || to_char(v_day, 'YYYY-MM-DD') || coalesce(' — ' || v_note, '');
    update public.request_approvals set status = 'cancelled' where request_id = v_req.id and status in ('waiting', 'pending');
    update public.requests
       set status = 'cancelled', decided_by = v_admin, decided_at = now(), decision_note = left(v_text, 500), current_step = null
     where id = v_req.id;
    perform private.notify(v_req.employee_id, v_req.company_id, 'request_decided', 'أُلغيت إجازتك',
      private.request_summary(v_req.id) || E'\n' || v_text, '?tab=requests', 'request-' || v_req.id::text, 86400 * 7);
    perform public.audit_write(v_company, 'leave.cancelled_for_attendance', 'request', v_req.id::text,
      jsonb_build_object('employee_id', v_req.employee_id, 'event_id', v_ev.id, 'day', v_day, 'leave_type', v_req.leave_type,
                         'days', v_req.days, 'note', v_note));
    v_cancelled := true;
  end if;

  update public.attendance_events
     set needs_review = false, metadata = metadata || jsonb_build_object('review', v_review)
   where id = v_ev.id;

  -- The other flagged days of the same leave: the reason is gone. Cleared when it was the only reason, otherwise only the leave
  -- reason is removed.
  if p_decision = 'cancel_leave' then
    update public.attendance_events x
       set metadata = jsonb_set(x.metadata, '{suspect}', (x.metadata -> 'suspect') - 'on_approved_leave')
                      || case when private.review_only_leave(x.location_status, x.metadata)
                              then jsonb_build_object('review', v_review || jsonb_build_object('auto', true)) else '{}'::jsonb end,
           needs_review = x.needs_review and not private.review_only_leave(x.location_status, x.metadata)
     where x.employee_id = v_ev.employee_id and x.id <> v_ev.id and x.needs_review
       and x.metadata ->> 'leave_request_id' = v_req.id::text and x.metadata -> 'suspect' ? 'on_approved_leave';
  end if;

  perform public.audit_write(v_company, 'attendance.review_' || p_decision, 'attendance_event', v_ev.id::text,
    jsonb_build_object('employee_id', v_ev.employee_id, 'event_type', v_ev.event_type, 'occurred_at', v_ev.occurred_at,
                       'leave_request_id', v_req.id, 'leave_cancelled', v_cancelled, 'note', v_note));
  return jsonb_build_object('event_id', v_ev.id, 'decision', p_decision, 'leave_request_id', v_req.id,
                            'leave_cancelled', v_cancelled, 'leave_already_cancelled', p_decision = 'cancel_leave' and not v_cancelled);
end;
$$;
revoke all on function public.admin_resolve_leave_conflict(uuid, text, text) from public, anon;
grant execute on function public.admin_resolve_leave_conflict(uuid, text, text) to authenticated;
