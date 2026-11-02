-- Rollback of 20261102170000_phase15_leave_conflict.sql: record_punch back to the phase 13 text, the queue back to the phase 14 shape.
-- Events already flagged 'on_approved_leave' keep that mark in their metadata (the old panel shows them as "للمراجعة"); leaves that were
-- cancelled stay cancelled.
drop function if exists public.admin_resolve_leave_conflict(uuid, text, text);
drop function if exists public.admin_review_queue(integer);
create or replace function public.admin_review_queue(p_limit integer default 200)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, event_type public.attendance_event_type,
  occurred_at timestamp with time zone, location_status text, suspect text[], biometric text, missed_checkout boolean,
  offline boolean, sync_delay_s integer, needs_review boolean, review_total bigint)
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
         count(*) over ()
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  where ev.company_id = v_company and ev.needs_review
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 200), 1000), 1);
end;
$$;
revoke all on function public.admin_review_queue(integer) from public, anon;
grant execute on function public.admin_review_queue(integer) to authenticated;

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
    'location_status', v_status, 'needs_review', v_review, 'duplicate', false, 'missing_checkin', v_orphan);
end;
$$;
revoke all on function private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision,
  double precision, timestamp with time zone, jsonb) from public, anon, authenticated;
revoke all on function private.record_punch(uuid, text, text, numeric, text, uuid, text, text, double precision, double precision,
  double precision, timestamp with time zone, jsonb) from public, anon, authenticated;

drop function if exists private.review_only_leave(text, jsonb);
drop function if exists private.approved_leave_on(uuid, date);
