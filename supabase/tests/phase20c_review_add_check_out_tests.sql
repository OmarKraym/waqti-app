-- Phase 20c: the admin adds the forgotten CHECK-OUT from the review window (public.admin_resolve_review, action 'add_check_out').
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
-- admin_resolve_review as the admin, back to the test's own role afterwards
create function pg_temp.res(adm uuid, ev uuid, act text, at timestamptz default null, note text default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_resolve_review(ev, act, at, note);
  reset role;
  return r;
end $$;
-- the same, but returns the error text instead of raising
create function pg_temp.res_err(adm uuid, ev uuid, act text, at timestamptz default null, note text default null) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.admin_resolve_review(ev, act, at, note);
    r := '';
  exception when others then r := sqlerrm;
  end;
  reset role;
  return r;
end $$;
-- the admin adds a check-in the employee forgot to close (phase 20): a session "missed_checkout", the check-in flagged for review
create function pg_temp.add_in(adm uuid, emp uuid, at timestamptz) returns uuid language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_add_punch(emp, 'check_in', at, 'نسي التسجيل');
  reset role;
  return (r ->> 'event_id')::uuid;
end $$;
-- a flagged "missed check-out" check-in written directly (any time, even a few hours ago), with its session
create function pg_temp.flagged(emp uuid, at timestamptz) returns uuid language plpgsql as $$
declare e uuid; tz text;
begin
  select c.timezone into tz from public.employees x join public.companies c on c.id = x.company_id where x.id = emp;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (emp, 'check_in', at, true, 'password', 'not_requested', true, 'none', jsonb_build_object('missed_checkout', true))
  returning id into e;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (emp, (at at time zone tz)::date, e, 'missed_checkout');
  return e;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; d uuid; v_comp uuid; v_comp2 uuid; v_tz text; v_today date;
  wd date[]; r jsonb; s text; n int; e_other uuid; o_in uuid;
  b_in uuid; a_in uuid; c_in1 uuid; c_in2 uuid; d_in1 uuid; d_in2 uuid; n_in uuid; x_in uuid; f_in uuid; w_out uuid; w_in uuid;
  new_out uuid; sess uuid; l record; q record; t_out timestamptz;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) and e.company_id = v_comp order by employee_number limit 1;
  select id into d from public.employees e where e.is_active and e.id not in (v_admin, a, b, c) and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone v_tz)::date;
  select array_agg(g::date order by g desc) into wd from generate_series(v_today - 12, v_today - 1, interval '1 day') g where extract(dow from g) <> 5;
  delete from public.attendance_sessions where employee_id in (a, b, c, d);
  delete from public.attendance_events where employee_id in (a, b, c, d);
  update public.companies set late_grace_min = 15, early_grace_min = 10, late_rule = 'all_after_grace', punch_windows_enabled = false where id = v_comp;
  update public.employees set late_grace_min = null, early_grace_min = null where id in (a, b, c, d);

  -- ---------------------------------------------------------------- the flagged check-in of B (made by admin_add_punch, phase 20)
  b_in := pg_temp.add_in(v_admin, b, (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok((select e.needs_review and (e.metadata ->> 'missed_checkout')::boolean from public.attendance_events e where e.id = b_in)
                     and (select s.status::text = 'missed_checkout' from public.attendance_sessions s where s.check_in_event_id = b_in),
                     'setup: a check-in on an earlier day waits for its check-out (flagged, session missed_checkout)');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into q from public.admin_review_queue(200) x where x.event_id = b_in;
  reset role;
  perform pg_temp.ok(q.event_id is not null and q.missed_checkout and q.event_type = 'check_in', 'it is in the review queue as a check-in with missed_checkout true', row(q.missed_checkout, q.event_type)::text);

  -- ---------------------------------------------------------------- who may call it, and what it refuses
  perform pg_temp.as_user(b);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_review(%L, ''add_check_out'', %L, ''x'')', b_in, (wd[1] + time '16:00') at time zone v_tz));
  reset role;
  perform pg_temp.ok(s <> '' and s <> 'x', 'an employee cannot use it', s);
  perform pg_temp.ok(not exists (select 1 from public.attendance_events where employee_id = b and event_type = 'check_out'), 'and nothing was written');

  s := pg_temp.res_err(v_admin, b_in, 'add_check_out', null);
  perform pg_temp.ok(s = 'invalid_time', 'a time is required', s);
  s := pg_temp.res_err(v_admin, b_in, 'add_check_out', (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'the same minute as the check-in is refused', s);
  s := pg_temp.res_err(v_admin, b_in, 'add_check_out', (wd[1] + time '07:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'before the check-in is refused', s);
  s := pg_temp.res_err(v_admin, b_in, 'add_check_out', (wd[1] + time '08:20') at time zone v_tz + interval '24 hours 1 minute');
  perform pg_temp.ok(s = 'invalid_time', 'more than 24 hours after the check-in is refused', s);
  s := pg_temp.res_err(v_admin, gen_random_uuid(), 'add_check_out', (wd[1] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'an unknown event', s);
  s := pg_temp.res_err(v_admin, b_in, 'delete', (wd[1] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'an unknown action is still refused', s);
  s := pg_temp.res_err(v_admin, b_in, 'add_check_in', (wd[1] + time '07:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'add_check_in on a check-in is still refused', s);
  perform pg_temp.ok((select e.needs_review from public.attendance_events e where e.id = b_in)
                     and not exists (select 1 from public.attendance_events where employee_id = b and event_type = 'check_out'),
                     'a refused call changes nothing (still flagged, no check-out)');

  -- another company's event is invisible
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار الانصراف', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'review-out-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e_other;
  o_in := pg_temp.flagged(e_other, (wd[1] + time '08:00') at time zone v_tz);
  s := pg_temp.res_err(v_admin, o_in, 'add_check_out', (wd[1] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'an event of another company', s);

  -- it only fits a check-in that waits for its check-out
  n_in := pg_temp.flagged(c, (wd[3] + time '08:00') at time zone v_tz);
  update public.attendance_events set metadata = '{}'::jsonb where id = n_in;
  s := pg_temp.res_err(v_admin, n_in, 'add_check_out', (wd[3] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'a flagged check-in that is not "missed check-out" is refused', s);
  update public.attendance_events set metadata = jsonb_build_object('missed_checkout', true) where id = n_in;
  delete from public.attendance_sessions where check_in_event_id = n_in;
  s := pg_temp.res_err(v_admin, n_in, 'add_check_out', (wd[3] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'a check-in with no waiting session is refused', s);
  delete from public.attendance_events where id = n_in;

  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (c, 'check_out', (wd[3] + time '16:00') at time zone v_tz, true, 'password', 'not_requested', true, 'none', '{"suspect":["missing_checkin"]}'::jsonb)
  returning id into x_in;
  s := pg_temp.res_err(v_admin, x_in, 'add_check_out', (wd[3] + time '17:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'a check-out flagged "missing check-in" is refused (that one takes add_check_in)', s);
  delete from public.attendance_events where id = x_in;

  -- ---------------------------------------------------------------- the check-out of B
  sess := (select s.id from public.attendance_sessions s where s.check_in_event_id = b_in);
  r := pg_temp.res(v_admin, b_in, 'add_check_out', (wd[1] + time '16:05') at time zone v_tz, '  نسي الانصراف مساءً  ');
  new_out := (r ->> 'check_out_event_id')::uuid;
  perform pg_temp.ok((r ->> 'event_id')::uuid = b_in and r ->> 'action' = 'add_check_out' and new_out is not null and r -> 'check_in_event_id' = 'null'::jsonb,
                     'the result names the flagged check-in, the action and the new check-out', r::text);
  perform pg_temp.ok((select e.event_type = 'check_out' and e.authentication_method = 'admin' and e.location_status = 'not_requested'
                             and e.location_policy = 'none' and e.within_geofence and not e.needs_review and e.employee_id = b
                             and e.occurred_at = (wd[1] + time '16:05') at time zone v_tz
                      from public.attendance_events e where e.id = new_out),
                     'a check-out of that employee, at the time given, by the admin, no location, nothing to review');
  perform pg_temp.ok((select e.metadata ->> 'source' = 'admin_correction' and (e.metadata ->> 'corrects_event')::uuid = b_in
                             and e.metadata -> 'review' ->> 'action' = 'add_check_out' and (e.metadata -> 'review' ->> 'by')::uuid = v_admin
                             and e.metadata -> 'review' ->> 'note' = 'نسي الانصراف مساءً'
                      from public.attendance_events e where e.id = new_out),
                     'it says it is a correction of the check-in, who did it and the note (trimmed)');
  perform pg_temp.ok((select s.status::text = 'closed' and s.check_out_event_id = new_out and s.check_in_event_id = b_in and s.work_date = wd[1]
                      from public.attendance_sessions s where s.id = sess),
                     'that very session is closed with the new check-out (same row, same work day)');
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = b) = 1, 'no second session was created');
  perform pg_temp.ok((select not e.needs_review and (e.metadata ->> 'missed_checkout')::boolean is false
                             and e.metadata -> 'review' ->> 'action' = 'add_check_out'
                      from public.attendance_events e where e.id = b_in),
                     'the check-in is resolved: not for review, "missed check-out" false, the review is recorded on it');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.review_add_check_out' and target_id = b_in::text
                            and (details ->> 'added_check_out')::uuid = new_out and details ->> 'note' = 'نسي الانصراف مساءً') = 1,
                     'it is in the audit log (attendance.review_add_check_out)');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue(200) x where x.event_id = b_in;
  select * into l from public.admin_list_attendance(null, null, b, null, 50, 0) x where x.event_id = new_out;
  reset role;
  perform pg_temp.ok(n = 0, 'it left the review queue');
  perform pg_temp.ok(l.event_id is not null and l.source = 'admin_correction' and l.event_type = 'check_out', 'the attendance list shows the check-out as an admin correction', row(l.source, l.event_type)::text);
  s := pg_temp.res_err(v_admin, b_in, 'add_check_out', (wd[1] + time '17:00') at time zone v_tz);
  perform pg_temp.ok(s = 'already_resolved', 'a second call on the same check-in is refused', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = b and event_type = 'check_out') = 1, 'still one check-out');

  -- ---------------------------------------------------------------- the same for a check-in the SYSTEM flagged (close_missed_checkout)
  update public.companies set punch_windows_enabled = true where id = v_comp;
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, true, time '08:00', time '16:00', v_comp from generate_series(0, 6) g;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[2] + time '08:05') at time zone v_tz, true, 'password', 'none') returning id into a_in;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (a, wd[2], a_in, 'open');
  perform pg_temp.ok(private.close_missed_checkout(a, now()), 'setup: the system closed his forgotten session as missed_checkout');
  update public.companies set punch_windows_enabled = false where id = v_comp;
  perform pg_temp.ok((select e.needs_review and (e.metadata ->> 'missed_checkout')::boolean from public.attendance_events e where e.id = a_in), 'setup: its check-in is flagged');
  r := pg_temp.res(v_admin, a_in, 'add_check_out', (wd[2] + time '16:10') at time zone v_tz, 'نسي البصمة');
  new_out := (r ->> 'check_out_event_id')::uuid;
  perform pg_temp.ok((select s.status::text = 'closed' and s.check_out_event_id = new_out and s.check_in_event_id = a_in from public.attendance_sessions s where s.employee_id = a),
                     'the system-flagged session is closed with the new check-out');
  perform pg_temp.ok((select not e.needs_review and (e.metadata ->> 'missed_checkout')::boolean is false from public.attendance_events e where e.id = a_in), 'and its check-in is resolved');

  -- ---------------------------------------------------------------- two forgotten check-ins on one day: each closes its own session
  c_in1 := pg_temp.add_in(v_admin, c, (wd[4] + time '08:00') at time zone v_tz);
  c_in2 := pg_temp.add_in(v_admin, c, (wd[4] + time '14:00') at time zone v_tz);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = c and status::text = 'missed_checkout') = 2, 'setup: two waiting sessions on one day');
  s := pg_temp.res_err(v_admin, c_in1, 'add_check_out', (wd[4] + time '15:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'the first one cannot end after the second one started (an event in between)', s);
  r := pg_temp.res(v_admin, c_in1, 'add_check_out', (wd[4] + time '12:00') at time zone v_tz);
  perform pg_temp.ok((select s.status::text = 'closed' and s.check_out_event_id = (r ->> 'check_out_event_id')::uuid from public.attendance_sessions s where s.check_in_event_id = c_in1),
                     'the first session is closed by its own check-out');
  perform pg_temp.ok((select s.status::text = 'missed_checkout' and s.check_out_event_id is null from public.attendance_sessions s where s.check_in_event_id = c_in2)
                     and (select e.needs_review from public.attendance_events e where e.id = c_in2),
                     'the second session is untouched (still waiting, still flagged)');
  r := pg_temp.res(v_admin, c_in2, 'add_check_out', (wd[4] + time '18:00') at time zone v_tz);
  perform pg_temp.ok((select s.status::text = 'closed' and s.check_out_event_id = (r ->> 'check_out_event_id')::uuid from public.attendance_sessions s where s.check_in_event_id = c_in2)
                     and (select count(*) from public.attendance_sessions where employee_id = c and status::text = 'closed') = 2,
                     'the second one is closed by its own check-out; both sessions closed');
  -- the other order
  d_in1 := pg_temp.add_in(v_admin, d, (wd[4] + time '08:00') at time zone v_tz);
  d_in2 := pg_temp.add_in(v_admin, d, (wd[4] + time '14:00') at time zone v_tz);
  r := pg_temp.res(v_admin, d_in2, 'add_check_out', (wd[4] + time '18:00') at time zone v_tz);
  s := pg_temp.res_err(v_admin, d_in1, 'add_check_out', (wd[4] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'the first one still cannot pass the second check-in after the second was closed', s);
  r := pg_temp.res(v_admin, d_in1, 'add_check_out', (wd[4] + time '13:00') at time zone v_tz);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = d and status::text = 'closed') = 2
                     and (select s.check_in_event_id = d_in1 from public.attendance_sessions s where s.check_out_event_id = (r ->> 'check_out_event_id')::uuid),
                     'closed in the opposite order too: each check-out belongs to its own check-in');

  -- ---------------------------------------------------------------- a night shift, the future, and "now"
  f_in := pg_temp.flagged(b, now() - interval '3 hours');
  s := pg_temp.res_err(v_admin, f_in, 'add_check_out', now() + interval '5 minutes');
  perform pg_temp.ok(s = 'invalid_time', 'a time in the future is refused', s);
  r := pg_temp.res(v_admin, f_in, 'add_check_out', now() - interval '1 hour');
  perform pg_temp.ok((r ->> 'check_out_event_id') is not null, 'a time in the past is accepted');
  w_in := pg_temp.flagged(a, (wd[5] + time '22:00') at time zone v_tz);
  r := pg_temp.res(v_admin, w_in, 'add_check_out', (wd[5] + 1 + time '06:00') at time zone v_tz, 'وردية ليلية');
  w_out := (r ->> 'check_out_event_id')::uuid;
  perform pg_temp.ok((select s.status::text = 'closed' and s.work_date = wd[5] and s.check_out_event_id = w_out from public.attendance_sessions s where s.check_in_event_id = w_in)
                     and (select e.occurred_at = (wd[5] + 1 + time '06:00') at time zone v_tz from public.attendance_events e where e.id = w_out),
                     'a night shift: the check-out the next morning closes the session of the evening before (work day stays the first one)');

  -- the edges of the rules: exactly 24 hours is allowed; the exact minute of the next event is not; the session must be waiting
  x_in := pg_temp.flagged(b, (wd[7] + time '08:00') at time zone v_tz);
  r := pg_temp.res(v_admin, x_in, 'add_check_out', (wd[7] + time '08:00') at time zone v_tz + interval '24 hours');
  perform pg_temp.ok((r ->> 'check_out_event_id') is not null, 'exactly 24 hours after the check-in is accepted', r::text);
  d_in1 := pg_temp.flagged(d, (wd[8] + time '08:00') at time zone v_tz);
  d_in2 := pg_temp.flagged(d, (wd[8] + time '14:00') at time zone v_tz);
  s := pg_temp.res_err(v_admin, d_in1, 'add_check_out', (wd[8] + time '14:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'the exact minute of the next event of the employee is refused', s);
  update public.attendance_sessions set status = 'open' where check_in_event_id = d_in1;
  s := pg_temp.res_err(v_admin, d_in1, 'add_check_out', (wd[8] + time '12:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'a flagged check-in whose session is not waiting is refused', s);

  -- ---------------------------------------------------------------- the old actions are unchanged
  x_in := pg_temp.flagged(d, (wd[6] + time '08:00') at time zone v_tz);
  r := pg_temp.res(v_admin, x_in, 'accept', null, 'تم التحقق');
  perform pg_temp.ok(r ? 'event_id' and r ->> 'action' = 'accept' and r -> 'check_in_event_id' = 'null'::jsonb and r ? 'check_out_event_id' and r -> 'check_out_event_id' = 'null'::jsonb,
                     'accept: same result as before, plus an empty check_out_event_id', r::text);
  perform pg_temp.ok((select s.status::text = 'missed_checkout' and s.check_out_event_id is null from public.attendance_sessions s where s.employee_id = d and s.work_date = wd[6])
                     and (select (e.metadata ->> 'missed_checkout')::boolean and not e.needs_review from public.attendance_events e where e.id = (r ->> 'event_id')::uuid),
                     'accept: the session stays "missed_checkout" (nobody added a check-out) and the check-in leaves the queue');
  s := pg_temp.res_err(v_admin, (r ->> 'event_id')::uuid, 'add_check_out', (wd[6] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'already_resolved', 'after «قبول» the check-in is settled: no check-out can be added from the review window', s);
  perform pg_temp.ok(true, 'END part 1');
end
$tests$;

do $report$
declare v text;
begin
  -- a block that stopped on an error must show as a failure, not as fewer passes
  insert into t_res (name, ok, detail) select 'part ' || blk.k || ' did not finish', false, 'a block stopped on an error' from generate_series(1, 1) blk(k)
  where not exists (select 1 from t_res where t_res.name = 'END part ' || blk.k);
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
