-- Phase 23: what the employee forgot shows up for the admin. An open session that ran past its check-out time is closed as "missed
-- check-out" when the admin opens the review queue (24 hours rule where no window rule can judge); a working day with no movement after
-- shift start + grace is listed (admin_list_missing_checkins) and the admin may say "absent" (admin_dismiss_missing_checkin).
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
create function pg_temp.sched_all(p_emp uuid, p_comp uuid) returns void language plpgsql as $$
begin
  delete from public.employee_work_schedules where employee_id = p_emp;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select p_emp, g, true, '08:00', '16:00', p_comp from generate_series(0, 6) g;
end $$;
create function pg_temp.mk_leave(p_emp uuid, p_comp uuid, p_tz text, p_type text, p_from date, p_to date, p_status text default 'approved')
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.requests (employee_id, company_id, request_type, leave_type, status, start_at, end_at, days, decided_at)
  values (p_emp, p_comp, 'leave', p_type, p_status::public.request_status,
          greatest(p_from, (now() at time zone p_tz)::date)::timestamp at time zone p_tz,
          (p_to + 1)::timestamp at time zone p_tz, private.leave_days(p_emp, p_from, p_to), case when p_status <> 'pending' then now() end)
  returning id into v;
  update public.requests set start_at = p_from::timestamp at time zone p_tz where id = v;
  insert into public.request_approvals (company_id, request_id, step_order, approver_kind, status)
  values (p_comp, v, 1, 'hr', case p_status when 'approved' then 'approved' when 'rejected' then 'rejected' else 'pending' end);
  return v;
end $$;
create function pg_temp.clean(p_emp uuid) returns void language plpgsql as $$
begin
  delete from public.attendance_sessions where employee_id = p_emp;
  delete from public.attendance_events where employee_id = p_emp;
  delete from public.requests where employee_id = p_emp;
  delete from public.notifications where user_id = p_emp;
end $$;
-- the first and last local day of a request, and how many working days it counts
create function pg_temp.span(p_req uuid) returns text language sql as $$
  select ((r.start_at at time zone c.timezone)::date)::text || '..' || (((r.end_at - interval '1 second') at time zone c.timezone)::date)::text || ' d=' || r.days::text
  from public.requests r join public.companies c on c.id = r.company_id where r.id = p_req $$;
create function pg_temp.punch(p_emp uuid, p_tz text, p_action text, p_at timestamptz, p_meta jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select private.record_punch(p_emp, 'none', 'flag', 100, p_tz, gen_random_uuid(), p_action, 'not_requested', null, null, null, p_at, p_meta) $$;
create function pg_temp.used(p_emp uuid, p_year int) returns numeric language sql as $$
  select (private.leave_balance(p_emp, 'annual', p_year) ->> 'used')::numeric $$;

create function pg_temp.sched9(p_emp uuid, p_comp uuid) returns void language plpgsql as $$
begin
  delete from public.employee_work_schedules where employee_id = p_emp;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select p_emp, g, true, '09:00', '17:00', p_comp from generate_series(0, 6) g;
end $$;
-- a check-in that nobody closed (direct insert: the punch rules would refuse a check-in that old)
create function pg_temp.open_sess(p_emp uuid, p_at timestamptz) returns uuid language plpgsql as $$
declare v_ev uuid;
begin
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (p_emp, 'check_in', p_at, true, 'password', 'not_requested', false, 'none', '{}'::jsonb) returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status)
  values (p_emp, (p_at at time zone 'Africa/Tripoli')::date, v_ev, 'open');
  return v_ev;
end $$;
create function pg_temp.sess(p_ev uuid) returns text language sql as $$
  select s.status::text from public.attendance_sessions s where s.check_in_event_id = p_ev $$;
-- the days the list shows for an employee, oldest first
create function pg_temp.md(p_emp uuid) returns text language sql as $$
  select coalesce(string_agg(m.day::text, ',' order by m.day), '')
  from private.missing_checkins((select e.company_id from public.employees e where e.id = p_emp), p_emp) m $$;
-- the days today-from .. today-to (oldest first) as the same text
create function pg_temp.days(p_today date, p_from int, p_to int) returns text language sql as $$
  select coalesce(string_agg((p_today - g)::text, ',' order by p_today - g), '') from generate_series(p_to, p_from) g $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; r jsonb; s text; today date; st jsonb; n int;
  ev1 uuid; ev2 uuid; ev3 uuid; ev4 uuid; ev5 uuid; v_comp2 uuid; e2 uuid; ev6 uuid; l1 uuid;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  update public.employees set location_policy = 'none', late_grace_min = null, created_at = now() - interval '60 days', deleted_at = null, is_active = true where id in (a, b);
  update public.companies set punch_windows_enabled = false, late_grace_min = 0 where id = v_comp;
  perform pg_temp.sched9(a, v_comp);
  perform pg_temp.sched9(b, v_comp);
  perform pg_temp.clean(a);
  perform pg_temp.clean(b);
  delete from public.attendance_day_decisions where employee_id in (a, b);
  today := (now() at time zone v_tz)::date;

  -- ================================================================ 1. open sessions nobody closed
  ev1 := pg_temp.open_sess(a, now() - interval '30 hours');
  ev2 := pg_temp.open_sess(b, now() - interval '2 hours');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue() q
   where q.event_id = ev1 and q.event_type = 'check_in' and q.missed_checkout and q.needs_review and q.employee_id = a;
  reset role;
  perform pg_temp.ok(n = 1, 'windows off: a check-in 30 hours old with no check-out is in the review queue as a missed check-out', n::text);
  perform pg_temp.ok(pg_temp.sess(ev1) = 'missed_checkout', 'its session is closed as missed_checkout', pg_temp.sess(ev1));
  perform pg_temp.ok(pg_temp.sess(ev2) = 'open' and not (select needs_review from public.attendance_events where id = ev2),
                     'a check-in 2 hours old is left alone', pg_temp.sess(ev2));

  -- the existing button now has something to work on
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_review(ev1, 'add_check_out', now() - interval '22 hours', 'forgot');
  select count(*) into n from public.admin_review_queue() q where q.event_id = ev1;
  reset role;
  perform pg_temp.ok(r ->> 'action' = 'add_check_out' and pg_temp.sess(ev1) = 'closed' and n = 0,
                     'add_check_out works on it: the session is closed and the row leaves the queue', r::text);
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ->> 'next_action' = 'check_in' and st -> 'open_session' = 'null'::jsonb, 'and the employee can check in again', st::text);

  -- the 24 hours line
  update public.attendance_events set occurred_at = now() - interval '23 hours' where id = ev2;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue() q where q.event_id = ev2;
  reset role;
  perform pg_temp.ok(n = 0 and pg_temp.sess(ev2) = 'open', 'a check-in 23 hours old is not flagged yet', n::text);
  update public.attendance_events set occurred_at = now() - interval '25 hours' where id = ev2;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue() q where q.event_id = ev2 and q.missed_checkout;
  reset role;
  perform pg_temp.ok(n = 1 and pg_temp.sess(ev2) = 'missed_checkout', 'and one 25 hours old is', n::text);

  -- windows ON and a schedule: the employee's own window rule judges (same as when he opens the app)
  perform pg_temp.clean(a);
  perform pg_temp.clean(b);
  update public.companies set punch_windows_enabled = true where id = v_comp;
  ev3 := pg_temp.open_sess(a, now() - interval '30 hours');
  ev4 := pg_temp.open_sess(b, now() - interval '1 hour');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue() q where q.event_id in (ev3, ev4);
  reset role;
  perform pg_temp.ok(pg_temp.sess(ev3) = 'missed_checkout' and pg_temp.sess(ev4) = 'open' and n = 1,
                     'windows on + schedule: the old session is flagged by the window rule, the recent one is not', pg_temp.sess(ev3) || '/' || pg_temp.sess(ev4));
  -- windows ON but no schedule for him: the 24 hours line again
  perform pg_temp.clean(a);
  delete from public.employee_work_schedules where employee_id = a;
  ev5 := pg_temp.open_sess(a, now() - interval '30 hours');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue() q where q.event_id = ev5;
  reset role;
  perform pg_temp.ok(n = 1 and pg_temp.sess(ev5) = 'missed_checkout', 'windows on but no schedule: 24 hours after the check-in', n::text);

  -- another company is never touched, and a non-admin gets nothing
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار المرحلة 23', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'forgot23-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2;
  update public.companies set punch_windows_enabled = false where id = v_comp2;
  ev6 := pg_temp.open_sess(e2, now() - interval '40 hours');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_review_queue();
  reset role;
  perform pg_temp.ok(pg_temp.sess(ev6) = 'open', 'another company''s old open session is not touched by this admin', pg_temp.sess(ev6));
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err('select count(*) from public.admin_review_queue()');
  reset role;
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot open the queue', s);

  -- ================================================================ 2. check-ins nobody made
  update public.companies set punch_windows_enabled = false where id = v_comp;
  perform pg_temp.sched9(a, v_comp);
  perform pg_temp.clean(a);
  perform pg_temp.clean(b);
  perform pg_temp.ok(pg_temp.md(a) = pg_temp.days(today, 6, 0) and pg_temp.md(b) = pg_temp.days(today, 6, 0),
                     'no movement at all: the last 7 working days (today included, not the 8th) are listed', pg_temp.md(a));

  -- grace: the company value, and his own value wins
  update public.companies set late_grace_min = 240 where id = v_comp;
  perform pg_temp.ok(pg_temp.md(a) = pg_temp.days(today, 6, 1), 'company grace 240 minutes: today is not listed yet (shift 09:00), the other days are', pg_temp.md(a));
  update public.employees set late_grace_min = 0 where id = a;
  perform pg_temp.ok(pg_temp.md(a) = pg_temp.days(today, 6, 0) and pg_temp.md(b) = pg_temp.days(today, 6, 1),
                     'his own grace (0) wins over the company''s', pg_temp.md(a) || ' / ' || pg_temp.md(b));
  update public.employees set late_grace_min = null where id = a;
  update public.companies set late_grace_min = 0 where id = v_comp;

  -- a movement on a day takes that day out; the punch of today takes today out
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  perform pg_temp.ok(pg_temp.md(a) = pg_temp.days(today, 6, 1), 'a check-in today takes today out of the list', pg_temp.md(a));
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (a, 'check_in', now() - interval '3 days', true, 'password', 'not_requested', false, 'none', '{}'::jsonb);
  perform pg_temp.ok(pg_temp.md(a) !~ (today - 3)::text, 'and any movement on another day takes that day out', pg_temp.md(a));
  perform pg_temp.clean(a);

  -- leave, holiday, day off
  l1 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today - 2, today - 1);
  perform pg_temp.ok(pg_temp.md(a) = pg_temp.days(today, 6, 3) || ',' || today::text or pg_temp.md(a) = (pg_temp.days(today, 6, 3) || ',' || today::text),
                     'days covered by an approved leave are not listed', pg_temp.md(a));
  perform pg_temp.clean(a);
  insert into public.company_holidays (company_id, name, start_date, end_date) values (v_comp, 'عطلة اختبار 23', today - 4, today - 4);
  perform pg_temp.ok(pg_temp.md(a) !~ (today - 4)::text and pg_temp.md(a) ~ (today - 3)::text, 'a company holiday is not listed', pg_temp.md(a));
  delete from public.company_holidays where company_id = v_comp and name = 'عطلة اختبار 23';
  update public.employee_work_schedules set is_workday = false where employee_id = a and weekday = extract(dow from (today - 5))::int;
  perform pg_temp.ok(pg_temp.md(a) !~ (today - 5)::text and pg_temp.md(a) ~ (today - 6)::text, 'a day off of his schedule is not listed', pg_temp.md(a));
  perform pg_temp.sched9(a, v_comp);

  -- who is not listed at all
  delete from public.employee_work_schedules where employee_id = b;
  perform pg_temp.ok(pg_temp.md(b) = '', 'no schedule, no shift start, no row', pg_temp.md(b));
  perform pg_temp.sched9(b, v_comp);
  update public.employees set is_active = false where id = a;
  perform pg_temp.ok(pg_temp.md(a) = '', 'a deactivated employee is not listed', pg_temp.md(a));
  update public.employees set is_active = false, deleted_at = now() where id = a;
  perform pg_temp.ok(pg_temp.md(a) = '', 'a deleted employee is not listed', pg_temp.md(a));
  update public.employees set is_active = true, deleted_at = null, created_at = now() - interval '2 days' where id = a;
  perform pg_temp.ok(pg_temp.md(a) = pg_temp.days(today, 2, 0), 'days before the employee was created are not listed', pg_temp.md(a));
  update public.employees set created_at = now() - interval '60 days' where id = a;

  -- ================================================================ 3. the admin's decision
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_list_missing_checkins() m where m.employee_id = a and m.day = today - 1 and m.grace_min = 0 and m.shift_start is not null;
  reset role;
  perform pg_temp.ok(n = 1, 'the list returns the row for the admin (day, shift start, grace)', n::text);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_dismiss_missing_checkin(a, today - 1, 'لم يأتِ');
  reset role;
  perform pg_temp.ok(r ->> 'decision' = 'absent' and pg_temp.md(a) !~ (today - 1)::text and pg_temp.md(a) ~ (today - 2)::text,
                     'saying absent hides that day only', pg_temp.md(a));
  perform pg_temp.ok((select count(*) from public.attendance_day_decisions d where d.employee_id = a and d.day = today - 1 and d.company_id = v_comp
                      and d.decided_by = v_admin and d.note = 'لم يأتِ') = 1, 'the decision is kept with who and why');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.day_absent' and target_id = a::text) = 1, 'and the audit log has it');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_dismiss_missing_checkin(%L, %L)', a, today - 1));
  reset role;
  perform pg_temp.ok(s = 'already_resolved', 'a second decision for the same day is refused', s);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_dismiss_missing_checkin(%L, %L)', a, today + 1));
  reset role;
  perform pg_temp.ok(s = 'not_found', 'a day that is not in the list cannot be decided', s);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_dismiss_missing_checkin(%L, %L)', a, today));
  reset role;
  perform pg_temp.ok(s = 'not_found', 'nor a day on which he did punch', s);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_dismiss_missing_checkin(%L, %L)', e2, today));
  reset role;
  perform pg_temp.ok(s = 'not_found', 'nor another company''s employee', s);
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err('select count(*) from public.admin_list_missing_checkins()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot read the list', s);
  s := pg_temp.err(format('select public.admin_dismiss_missing_checkin(%L, %L)', b, today));
  reset role;
  perform pg_temp.ok(s = 'forbidden', 'nor decide', s);

  -- ================================================================ 4. who may call what
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_missing_checkins(integer)', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_list_missing_checkins(integer)', 'execute')
                     and not has_function_privilege('anon', 'public.admin_dismiss_missing_checkin(uuid, date, text)', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_dismiss_missing_checkin(uuid, date, text)', 'execute'),
                     'the two admin functions: authenticated yes, anon no');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.missing_checkins(uuid, uuid)', 'execute')
                     and not has_function_privilege('authenticated', 'private.close_forgotten_sessions(uuid)', 'execute'),
                     'the private helpers are not callable from outside');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.attendance_day_decisions', 'select')
                     and not has_table_privilege('anon', 'public.attendance_day_decisions', 'select')
                     and (select relrowsecurity from pg_class where oid = 'public.attendance_day_decisions'::regclass),
                     'the decisions table is closed (RLS on, no grants)');

  perform pg_temp.clean(a);
  perform pg_temp.clean(b);
  delete from public.attendance_day_decisions where employee_id in (a, b);
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
