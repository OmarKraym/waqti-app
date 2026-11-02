-- Phase 14: (1) the main button becomes "check out" when he forgot to check in and only the check-out window is open;
-- (2) the admin sees the punches that need a look (admin_review_queue) and decides (admin_resolve_review).
-- Rollback: 20261102160000_phase14_forgot_checkin_review_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('public.employee_attendance_state()') is null
     or to_regprocedure('private.punch_window(uuid, text, timestamptz)') is null
     or to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null then
    raise exception 'phase14: expected functions are missing';
  end if;
end
$guard$;

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

-- ---------------------------------------------------------------- admin: what needs a look
-- (the partial index attendance_events_review_idx (company_id, occurred_at desc) where needs_review already exists)

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

-- accept: the punch stays as recorded, the flag is cleared.
-- add_check_in: only for a check-out flagged missing_checkin; adds the check-in the employee forgot (at p_time, same local day,
--   before the check-out and after the employee's previous event) and closes a session around the pair.
create or replace function public.admin_resolve_review(p_event_id uuid, p_action text, p_time timestamp with time zone default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_admin uuid := (select auth.uid());
  v_ev public.attendance_events;
  v_tz text;
  v_in_id uuid;
  v_review jsonb;
begin
  if p_action is null or p_action not in ('accept', 'add_check_in') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id and ev.company_id = v_company;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  -- Same lock order as record_punch (employee first), so a resolve and a punch of the same employee cannot deadlock.
  perform 1 from public.employees e where e.id = v_ev.employee_id for update;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id for update;
  if not v_ev.needs_review then
    raise exception 'already_resolved' using errcode = 'P0001';
  end if;
  select c.timezone into v_tz from public.companies c where c.id = v_company;
  v_review := jsonb_build_object('action', p_action, 'by', v_admin, 'at', now(), 'note', left(nullif(trim(coalesce(p_note, '')), ''), 500));

  if p_action = 'add_check_in' then
    if v_ev.event_type <> 'check_out' or not coalesce(v_ev.metadata -> 'suspect' ? 'missing_checkin', false) then
      raise exception 'invalid_action' using errcode = '22023';
    end if;
    if p_time is null or p_time >= v_ev.occurred_at
       or (p_time at time zone v_tz)::date <> (v_ev.occurred_at at time zone v_tz)::date
       or exists (select 1 from public.attendance_events x where x.employee_id = v_ev.employee_id
                  and x.id <> v_ev.id and x.occurred_at >= p_time and x.occurred_at <= v_ev.occurred_at) then
      raise exception 'invalid_time' using errcode = 'P0001';
    end if;
    insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method,
                                          location_status, needs_review, location_policy, metadata)
    values (v_ev.employee_id, 'check_in', p_time, true, 'admin', 'not_requested', false, 'none',
            jsonb_build_object('source', 'admin_correction', 'corrects_event', v_ev.id, 'review', v_review))
    returning id into v_in_id;
    insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, check_out_event_id, status)
    values (v_ev.employee_id, (p_time at time zone v_tz)::date, v_in_id, v_ev.id, 'closed');
  end if;

  update public.attendance_events
     set needs_review = false, metadata = metadata || jsonb_build_object('review', v_review)
   where id = v_ev.id;
  perform public.audit_write(v_company, 'attendance.review_' || p_action, 'attendance_event', v_ev.id::text,
    jsonb_build_object('employee_id', v_ev.employee_id, 'event_type', v_ev.event_type, 'occurred_at', v_ev.occurred_at,
                       'added_check_in', v_in_id, 'added_at', case when v_in_id is null then null else p_time end, 'note', v_review -> 'note'));
  return jsonb_build_object('event_id', v_ev.id, 'action', p_action, 'check_in_event_id', v_in_id);
end;
$$;
revoke all on function public.admin_resolve_review(uuid, text, timestamp with time zone, text) from public, anon;
grant execute on function public.admin_resolve_review(uuid, text, timestamp with time zone, text) to authenticated;
