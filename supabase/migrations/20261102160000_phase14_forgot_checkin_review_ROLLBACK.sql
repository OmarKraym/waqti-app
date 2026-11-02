-- Rollback of 20261102160000_phase14_forgot_checkin_review.sql: back to the phase 13 state (no flip); the review functions are removed.
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

  -- Phase 13: may he record a check-out although he has no check-in (forgot it)? Only inside the check-out window,
  -- and not when his latest punch is already a check-out today.
  if v_open.id is null then
    select x.event_type, x.occurred_at into v_last from public.attendance_events x
    where x.employee_id = me.employee_id order by x.occurred_at desc, x.id desc limit 1;
    v_can_leave := not (found and v_last.event_type = 'check_out'
                        and (v_last.occurred_at at time zone me.timezone)::date = (v_now at time zone me.timezone)::date)
                   and (select w.allowed from private.punch_window(me.employee_id, 'check_out', v_now) w);
  end if;

  return jsonb_build_object(
    'employee', jsonb_build_object('full_name', me.full_name, 'employee_number', me.employee_number),
    'company', jsonb_build_object('name', me.company_name, 'timezone', me.timezone),
    'next_action', case when v_open.id is null then 'check_in' else 'check_out' end,
    'open_session', case when v_open.id is null then null else jsonb_build_object('started_at', v_started) end,
    'can_check_out_without_in', v_can_leave,
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

drop function if exists public.admin_resolve_review(uuid, text, timestamp with time zone, text);
drop function if exists public.admin_review_queue(integer);
