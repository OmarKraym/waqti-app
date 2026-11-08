-- Phase 20: the admin adds a check-in or a check-out the employee forgot.
--   public.admin_add_punch(employee, 'check_in' | 'check_out', time, reason) -> {event_id, event_type, session_id, session_status}
--   * A reason (3..500 letters) is required. The time must be in the past and at most 62 days back.
--   * The event is saved like a normal punch (so lateness, early leave and the deduction of phase 19 are counted by the time the admin
--     writes, exactly as for any punch): authentication_method 'admin', no location (location_status 'not_requested'),
--     metadata {source: 'admin_manual', reason, added_by}. It is in the audit log ('attendance.manual_add').
--   * check_in:  refused when the employee has an open session (open_session), when the time is the exact time of another event of his
--                (invalid_time), inside a closed session of his (overlaps_session), or right before a check-out with no check-in on the
--                same day (unpaired_checkout: that one is solved in the review queue with admin_resolve_review).
--                A session is created: 'open' when it is today and nothing comes after it (the employee is still at work),
--                otherwise 'missed_checkout' with the check-in flagged for review, like a forgotten check-out found by the system.
--   * check_out: closes the latest open / missed_checkout session that started before the time. Refused when there is none
--                (no_open_session), when more than 24 hours passed since its check-in, or when another event of the employee lies
--                between the check-in and the time (invalid_time). The "missed check-out" flag of the check-in is cleared.
--   * The employee does not have to be active (payroll may need a former employee's last days); he must belong to the admin's company.
-- Nothing existing is changed or deleted. Rollback: 20261108130000_phase20_admin_manual_punch_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regclass('public.attendance_sessions') is null
     or not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                    where t.typname = 'attendance_session_status' and e.enumlabel = 'missed_checkout') then
    raise exception 'phase20: the attendance phases (8a, 14) must be applied first';
  end if;
end
$guard$;

create or replace function public.admin_add_punch(p_employee_id uuid, p_type text, p_time timestamp with time zone, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_admin uuid := (select auth.uid());
  v_reason text := left(nullif(trim(coalesce(p_reason, '')), ''), 500);
  v_tz text;
  v_status public.attendance_session_status;
  v_flag boolean;
  v_has_later boolean;
  v_review jsonb;
  v_ev uuid;
  v_sess uuid;
  v_in_id uuid;
  v_in_at timestamptz;
  v_next record;
begin
  if p_type is null or p_type not in ('check_in', 'check_out') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_time is null or p_time > now() or p_time < now() - interval '62 days' then
    raise exception 'invalid_time' using errcode = 'P0001';
  end if;
  -- Same lock order as record_punch (the employee first), so an admin call and the employee's own punch cannot deadlock.
  perform 1 from public.employees e where e.id = p_employee_id and e.company_id = v_company for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  select c.timezone into v_tz from public.companies c where c.id = v_company;

  if exists (select 1 from public.attendance_events x where x.employee_id = p_employee_id and x.occurred_at = p_time) then
    raise exception 'invalid_time' using errcode = 'P0001';
  end if;

  if p_type = 'check_in' then
    if exists (select 1 from public.attendance_sessions s where s.employee_id = p_employee_id and s.status = 'open') then
      raise exception 'open_session' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.attendance_sessions s
               join public.attendance_events ci on ci.id = s.check_in_event_id
               join public.attendance_events co on co.id = s.check_out_event_id
               where s.employee_id = p_employee_id and s.status = 'closed'
                 and ci.occurred_at <= p_time and co.occurred_at >= p_time) then
      raise exception 'overlaps_session' using errcode = 'P0001';
    end if;
    -- the very next event: a check-out nobody paired with a check-in on the same day belongs to the review queue
    select x.id, x.event_type, x.occurred_at into v_next
    from public.attendance_events x where x.employee_id = p_employee_id and x.occurred_at > p_time
    order by x.occurred_at, x.id limit 1;
    v_has_later := found;
    if v_has_later and v_next.event_type = 'check_out'
       and (v_next.occurred_at at time zone v_tz)::date = (p_time at time zone v_tz)::date
       and not exists (select 1 from public.attendance_sessions s where s.check_out_event_id = v_next.id) then
      raise exception 'unpaired_checkout' using errcode = 'P0001';
    end if;
    -- still at work (today, nothing after it): open. Otherwise it waits for its check-out like a missed one.
    if v_has_later or (p_time at time zone v_tz)::date <> (now() at time zone v_tz)::date then
      v_status := 'missed_checkout';
    else
      v_status := 'open';
    end if;
    v_flag := v_status = 'missed_checkout';
    insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method,
                                          location_status, needs_review, location_policy, metadata)
    values (p_employee_id, 'check_in', p_time, true, 'admin', 'not_requested', v_flag, 'none',
            jsonb_build_object('source', 'admin_manual', 'reason', v_reason, 'added_by', v_admin)
              || case when v_flag then jsonb_build_object('missed_checkout', true) else '{}'::jsonb end)
    returning id into v_ev;
    insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status)
    values (p_employee_id, (p_time at time zone v_tz)::date, v_ev, v_status)
    returning id into v_sess;
  else
    select s.id, s.check_in_event_id, ci.occurred_at into v_sess, v_in_id, v_in_at
    from public.attendance_sessions s
    join public.attendance_events ci on ci.id = s.check_in_event_id
    where s.employee_id = p_employee_id and s.status in ('open', 'missed_checkout') and ci.occurred_at < p_time
    order by ci.occurred_at desc limit 1;
    if not found then
      raise exception 'no_open_session' using errcode = 'P0001';
    end if;
    if p_time > v_in_at + interval '24 hours'
       or exists (select 1 from public.attendance_events x
                  where x.employee_id = p_employee_id and x.id <> v_in_id and x.occurred_at > v_in_at and x.occurred_at <= p_time) then
      raise exception 'invalid_time' using errcode = 'P0001';
    end if;
    insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method,
                                          location_status, needs_review, location_policy, metadata)
    values (p_employee_id, 'check_out', p_time, true, 'admin', 'not_requested', false, 'none',
            jsonb_build_object('source', 'admin_manual', 'reason', v_reason, 'added_by', v_admin))
    returning id into v_ev;
    update public.attendance_sessions set status = 'closed', check_out_event_id = v_ev where id = v_sess;
    v_status := 'closed';
    -- the check-in no longer has a missing check-out: clear that flag (and the review it caused, unless something else needs a look)
    v_review := jsonb_build_object('action', 'add_check_out', 'by', v_admin, 'at', now(), 'note', v_reason);
    update public.attendance_events ci
       set metadata = ci.metadata || jsonb_build_object('missed_checkout', false, 'review', v_review),
           needs_review = case when coalesce(jsonb_array_length(ci.metadata -> 'suspect'), 0) = 0
                                    and ci.location_status in ('inside', 'recorded', 'not_requested')
                               then false else ci.needs_review end
     where ci.id = v_in_id and coalesce((ci.metadata ->> 'missed_checkout')::boolean, false);
  end if;

  perform public.audit_write(v_company, 'attendance.manual_add', 'attendance_event', v_ev::text,
    jsonb_build_object('employee_id', p_employee_id, 'event_type', p_type, 'occurred_at', p_time, 'reason', v_reason,
                       'session_id', v_sess, 'session_status', v_status));
  return jsonb_build_object('event_id', v_ev, 'event_type', p_type, 'session_id', v_sess, 'session_status', v_status);
end;
$$;
revoke all on function public.admin_add_punch(uuid, text, timestamp with time zone, text) from public, anon;
grant execute on function public.admin_add_punch(uuid, text, timestamp with time zone, text) to authenticated;
