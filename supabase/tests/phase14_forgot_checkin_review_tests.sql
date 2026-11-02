-- Phase 14: the button flips to check-out when he forgot to check in; the admin reviews and resolves flagged punches.
-- Run with: psql -v admin_email=<company admin email> -f <this file>   (supabase/local/test-db.sh runs it on a fresh copy)
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
grant all on t_res to public;
grant all on sequence t_res_n_seq to public;
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
-- Same shift on every weekday except `yday_dow`: start/end are given as offsets from the local "now" (so the test works at any hour).
create function pg_temp.sched(p_emp uuid, p_comp uuid, p_tz text, p_start interval, p_end interval,
                              p_yday_dow int default null, p_yday_start interval default null, p_yday_end interval default null) returns void
language plpgsql as $$
declare t time := (now() at time zone p_tz)::time;
begin
  delete from public.employee_work_schedules where employee_id = p_emp;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select p_emp, g, true,
         case when g = p_yday_dow then t + p_yday_start else t + p_start end,
         case when g = p_yday_dow then t + p_yday_end else t + p_end end,
         p_comp
  from generate_series(0, 6) g;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; r jsonb; st jsonb; s text; t0 timestamptz;
  v_ev uuid; v_mid timestamptz; v_in uuid; v_comp2 uuid; e2 uuid; v_ev2 uuid; n int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  delete from public.attendance_sessions where employee_id in (a, b);
  delete from public.attendance_events where employee_id in (a, b);
  update public.employees set location_policy = 'none' where id in (a, b);
  update public.companies set punch_windows_enabled = true, in_before_min = 30, in_after_min = 30, out_before_min = 30, out_after_min = 30
   where id = v_comp;

  -- ---------------------------------------------------------------- the flip
  -- the shift started 4 hours ago and ends in 10 minutes: the check-in window is over, the check-out window is open
  perform pg_temp.sched(a, v_comp, v_tz, interval '-4 hours', interval '10 minutes');
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_out' and (st ->> 'forgot_check_in')::boolean
                     and (st -> 'punch_window' ->> 'allowed')::boolean, 'check-in window over, check-out window open: the button is "check out"', st::text);
  perform pg_temp.ok(st -> 'open_session' = 'null'::jsonb, 'and there is still no open session');

  -- pressing it (as the employee) saves a flagged check-out
  perform pg_temp.as_user(a);
  set local role authenticated;
  r := public.employee_punch(gen_random_uuid(), 'check_out', 'not_requested', null, null, null, 'unsupported');
  reset role;
  perform pg_temp.ok(r ->> 'action' = 'check_out' and (r ->> 'missing_checkin')::boolean and (r ->> 'needs_review')::boolean,
                     'the flipped button saves a check-out flagged "missing_checkin"', r::text);
  v_ev := (r ->> 'event_id')::uuid;

  -- afterwards: not flipped again (his latest punch is a check-out today); the check-in window is still closed
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_in' and not (st ->> 'forgot_check_in')::boolean
                     and not (st ->> 'can_check_out_without_in')::boolean and not (st -> 'punch_window' ->> 'allowed')::boolean,
                     'after it: no flip, no second check-out offered, check-in is closed', st::text);

  -- inside the check-in window: no flip
  delete from public.attendance_sessions where employee_id = b;
  delete from public.attendance_events where employee_id = b;
  perform pg_temp.sched(b, v_comp, v_tz, interval '-10 minutes', interval '4 hours');
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_in' and not (st ->> 'forgot_check_in')::boolean, 'check-in window open: the button stays "check in"', st::text);

  -- between the two windows: neither
  perform pg_temp.sched(b, v_comp, v_tz, interval '-3 hours', interval '3 hours');
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_in' and not (st ->> 'forgot_check_in')::boolean and not (st -> 'punch_window' ->> 'allowed')::boolean,
                     'between the windows: still "check in", closed', st::text);

  -- windows off: no flip (the small link stays)
  update public.companies set punch_windows_enabled = false where id = v_comp;
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_in' and not (st ->> 'forgot_check_in')::boolean and (st ->> 'can_check_out_without_in')::boolean,
                     'windows off: no flip, the fallback offer stays', st::text);
  update public.companies set punch_windows_enabled = true where id = v_comp;

  -- open session: check-out as always, not "forgot"
  perform pg_temp.sched(b, v_comp, v_tz, interval '-10 minutes', interval '10 minutes');
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_out' and not (st ->> 'forgot_check_in')::boolean and st -> 'open_session' <> 'null'::jsonb,
                     'with an open session: check-out, not flagged as forgotten', st::text);
  delete from public.attendance_sessions where employee_id = b;
  delete from public.attendance_events where employee_id = b;

  -- an overtime period later today: the next CHECK-IN window opens later today ('too_early'), but the shift's check-out window is open
  perform pg_temp.sched(b, v_comp, v_tz, interval '-4 hours', interval '10 minutes');
  insert into public.overtime_assignments (company_id, employee_id, assigned_by, start_at, end_at, minutes, status, assign_key)
  values (v_comp, b, v_admin, now() + interval '3 hours', now() + interval '5 hours', 120, 'assigned', gen_random_uuid());
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_out' and (st ->> 'forgot_check_in')::boolean,
                     'next check-in window opens later today (too_early) but the check-out window is open: still flips', st::text);
  delete from public.overtime_assignments where employee_id = b;

  -- ---------------------------------------------------------------- admin review queue
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok((select count(*) from public.admin_review_queue() where event_id = v_ev and 'missing_checkin' = any(suspect)) = 1,
                     'the admin queue lists the flagged check-out with its reason');
  reset role;
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err('select count(*) from public.admin_review_queue()');
  reset role;
  perform pg_temp.ok(s <> '', 'an employee cannot read the queue', s);

  -- other company: invisible and untouchable
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'review-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status)
  values (e2, 'check_out', now() - interval '1 hour', true, true, 'not_requested') returning id into v_ev2;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok((select count(*) from public.admin_review_queue() where event_id = v_ev2) = 0, 'the queue shows only my company');
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''accept'')', v_ev2));
  reset role;
  perform pg_temp.ok(s = 'not_found', 'another company''s event cannot be resolved', s);

  -- ---------------------------------------------------------------- resolve
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''accept'')', v_ev));
  reset role;
  perform pg_temp.ok(s <> '', 'an employee cannot resolve', s);

  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''delete'')', v_ev));
  perform pg_temp.ok(s = 'invalid_action', 'unknown action refused', s);
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''add_check_in'', null)', v_ev));
  perform pg_temp.ok(s = 'invalid_time', 'add_check_in needs a time', s);
  select occurred_at into t0 from public.attendance_events where id = v_ev;
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''add_check_in'', %L)', v_ev, t0 + interval '1 minute'));
  perform pg_temp.ok(s = 'invalid_time', 'a check-in after the check-out is refused', s);
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''add_check_in'', %L)', v_ev, t0 - interval '2 days'));
  perform pg_temp.ok(s = 'invalid_time', 'a check-in on another day is refused', s);

  -- accept
  r := public.admin_resolve_review(v_ev, 'accept', null, 'تم التحقق');
  reset role;
  perform pg_temp.ok((select not needs_review and metadata -> 'review' ->> 'action' = 'accept' from public.attendance_events where id = v_ev),
                     'accept clears the flag and writes who/when to the event');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.review_accept' and target_id = v_ev::text) = 1, 'accept is in the audit log');
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = a) = 0, 'accept does not create a session');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''accept'')', v_ev));
  reset role;
  perform pg_temp.ok(s = 'already_resolved', 'a second resolve is refused', s);

  -- add_check_in: a new orphan for b, then the admin adds the missing check-in halfway through the day so far
  delete from public.attendance_sessions where employee_id = b;
  delete from public.attendance_events where employee_id = b;
  perform pg_temp.sched(b, v_comp, v_tz, interval '-4 hours', interval '10 minutes');
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_out', 'not_requested', null, null, null, now(), '{}'::jsonb);
  v_ev := (r ->> 'event_id')::uuid;
  select occurred_at into t0 from public.attendance_events where id = v_ev;
  v_mid := date_trunc('day', t0 at time zone v_tz) at time zone v_tz;
  t0 := v_mid + (t0 - v_mid) / 2;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_review(v_ev, 'add_check_in', t0, 'نسي البصمة');
  reset role;
  v_in := (r ->> 'check_in_event_id')::uuid;
  perform pg_temp.ok((select event_type = 'check_in' and authentication_method = 'admin' and not needs_review and occurred_at = t0
                      from public.attendance_events where id = v_in), 'the admin check-in is stored (method admin, no flag, at the chosen time)');
  perform pg_temp.ok((select s.status = 'closed' and s.check_in_event_id = v_in and s.check_out_event_id = v_ev
                      from public.attendance_sessions s where s.employee_id = b), 'a closed session joins the pair');
  perform pg_temp.ok((select not needs_review from public.attendance_events where id = v_ev), 'the check-out is no longer flagged');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.review_add_check_in' and target_id = v_ev::text
                      and details ->> 'added_check_in' = v_in::text) = 1, 'the correction is in the audit log with the added event');

  -- add_check_in is only for a check-out flagged missing_checkin
  update public.attendance_events set needs_review = true where id = v_in;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''add_check_in'', %L)', v_in, t0));
  reset role;
  perform pg_temp.ok(s = 'invalid_action', 'add_check_in on any other event is refused', s);

  -- the queue only lists unresolved ones now
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok((select count(*) from public.admin_review_queue() where event_id in (v_ev, (select id from public.attendance_events where employee_id = a and event_type = 'check_out'))) = 0,
                     'resolved items leave the queue');
  reset role;
end
$tests$;

do $report$
declare v text;
begin
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
