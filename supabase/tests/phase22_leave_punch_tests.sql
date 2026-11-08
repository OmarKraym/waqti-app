-- Phase 22: a punch on an approved-leave day is saved, NOT sent to review, and cancels that day of the leave (the employee is told);
-- the admin may restore the day as leave or confirm it as a normal day. The app state tells "on leave today".
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

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; r jsonb; s text; today date; st jsonb; n int; yr int;
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; l6 uuid; l7 uuid; x uuid;
  ev1 uuid; ev2 uuid; ev3 uuid; evp uuid; evx uuid; q record; q2 uuid; v_comp2 uuid; e2 uuid;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  update public.employees set location_policy = 'none' where id in (a, b);
  update public.companies set punch_windows_enabled = false where id = v_comp;
  perform pg_temp.sched_all(a, v_comp);
  perform pg_temp.sched_all(b, v_comp);
  perform pg_temp.clean(a);
  perform pg_temp.clean(b);
  today := (now() at time zone v_tz)::date;
  yr := extract(year from today)::int;

  -- ---------------------------------------------------------------- the state tells the employee he is on leave today
  l1 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 2);
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st -> 'leave_today' ->> 'request_id' = l1::text and st -> 'leave_today' ->> 'leave_type' = 'annual'
                     and st -> 'leave_today' ->> 'end_date' = (today + 2)::text, 'the state says: on approved leave today (type, last day, request)', (st -> 'leave_today')::text);
  perform pg_temp.ok((st -> 'punch_window' ->> 'allowed')::boolean and st ->> 'next_action' = 'check_in',
                     'the punch is not closed because of the leave', st::text);
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(st ? 'leave_today' and jsonb_typeof(st -> 'leave_today') = 'null', 'an employee with no leave gets leave_today = null', st::text);

  -- ---------------------------------------------------------------- the first punch of the day cancels that day, no review
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  ev1 := (r ->> 'event_id')::uuid;
  perform pg_temp.ok(r ->> 'action' = 'check_in' and not (r ->> 'needs_review')::boolean and (r ->> 'on_approved_leave')::boolean
                     and (r ->> 'leave_day_cancelled')::boolean, 'the check-in is saved, NOT sent to review, and says the day was cancelled', r::text);
  perform pg_temp.ok((select not needs_review and not coalesce(metadata -> 'suspect' ? 'on_approved_leave', false) and metadata -> 'leave_day' ->> 'request_id' = l1::text
                             and metadata -> 'leave_day' ->> 'leave_type' = 'annual' and metadata -> 'leave_day' ->> 'day' = today::text
                      from public.attendance_events where id = ev1), 'the event is clean and remembers which leave day it cancelled');
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = a and status = 'open') = 1, 'the session is open as usual');
  perform pg_temp.ok(pg_temp.span(l1) = (today + 1)::text || '..' || (today + 2)::text || ' d=2.0', 'the leave lost its first day (now tomorrow..day after)', pg_temp.span(l1));
  perform pg_temp.ok(private.approved_leave_on(a, today) is null and private.approved_leave_on(a, today + 1) = l1, 'today is no longer a leave day, tomorrow still is');
  perform pg_temp.ok(pg_temp.used(a, yr) = 2, 'the balance returns by itself (3 -> 2 days used)', pg_temp.used(a, yr)::text);
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'request_decided' and title like 'أُلغي يوم من إجازتك%') = 1,
                     'the employee is notified');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'leave.cancelled_by_punch' and target_id = l1::text
                      and details ->> 'event_id' = ev1::text and details ->> 'day' = today::text) = 1, 'the audit log has the cancellation');
  perform pg_temp.ok((select decision_note like '%' || today::text || '%' from public.requests where id = l1), 'the request note says which day and why');
  r := pg_temp.punch(a, v_tz, 'check_out', now() + interval '1 minute');
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and not (r ->> 'needs_review')::boolean and not (r ? 'leave_day_cancelled' and (r ->> 'leave_day_cancelled')::boolean),
                     'the check-out of the same day is plain: nothing more to cancel', r::text);
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'request_decided') = 1
                     and (select count(*) from public.audit_log where action = 'leave.cancelled_by_punch' and target_id = l1::text) = 1, 'and no second notification or audit row');
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(jsonb_typeof(st -> 'leave_today') = 'null', 'after that the state no longer says "on leave today"', (st -> 'leave_today')::text);
  -- tomorrow the leave is still there: a punch on that day cancels that day too
  perform pg_temp.ok(private.approved_leave_on(a, today + 2) = l1, 'the last day is still on leave');

  -- ---------------------------------------------------------------- a day in the middle splits the leave
  perform pg_temp.clean(a);
  l2 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today - 1, today + 1);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  perform pg_temp.ok((r ->> 'leave_day_cancelled')::boolean, 'a punch in the middle of a leave cancels that day', r::text);
  perform pg_temp.ok(pg_temp.span(l2) = (today - 1)::text || '..' || (today - 1)::text || ' d=1.0', 'the first part keeps the original request', pg_temp.span(l2));
  select id into x from public.requests where employee_id = a and id <> l2 and request_type = 'leave';
  perform pg_temp.ok(x is not null and pg_temp.span(x) = (today + 1)::text || '..' || (today + 1)::text || ' d=1.0'
                     and (select status = 'approved' and leave_type = 'annual' from public.requests where id = x), 'the rest becomes its own approved request', pg_temp.span(x));
  perform pg_temp.ok((select count(*) from public.request_approvals where request_id = x and status = 'approved') = 1, 'with the finished approval copied');
  perform pg_temp.ok(private.approved_leave_on(a, today) is null and private.approved_leave_on(a, today - 1) = l2 and private.approved_leave_on(a, today + 1) = x,
                     'before and after are still leave, the day itself is not');
  perform pg_temp.ok(pg_temp.used(a, yr) = 2, 'balance: 2 days used (3 - the day he came)', pg_temp.used(a, yr)::text);

  -- ---------------------------------------------------------------- a one-day leave is cancelled whole
  perform pg_temp.clean(a);
  l3 := pg_temp.mk_leave(a, v_comp, v_tz, 'sick', today, today);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  perform pg_temp.ok((select status = 'cancelled' and decided_at is not null from public.requests where id = l3), 'a one-day leave becomes cancelled', r::text);
  perform pg_temp.ok((select count(*) from public.request_approvals where request_id = l3 and status in ('waiting', 'pending')) = 0
                     and (select count(*) from public.request_approvals where request_id = l3 and status = 'approved') = 1, 'the approval history stays');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'request_decided' and title like 'أُلغيت إجازتك%') = 1, 'the notice says the leave was cancelled');

  -- ---------------------------------------------------------------- the last day of a leave
  perform pg_temp.clean(a);
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today - 2, today);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  perform pg_temp.ok(pg_temp.span(l4) = (today - 2)::text || '..' || (today - 1)::text || ' d=2.0', 'the last day goes: the leave ends yesterday', pg_temp.span(l4));

  -- ---------------------------------------------------------------- what does NOT cancel anything
  perform pg_temp.clean(b);
  l5 := pg_temp.mk_leave(b, v_comp, v_tz, 'sick', today, today, 'pending');
  r := pg_temp.punch(b, v_tz, 'check_in', now());
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and not (r ->> 'needs_review')::boolean, 'a pending leave is left alone', r::text);
  perform pg_temp.clean(b);
  l5 := pg_temp.mk_leave(b, v_comp, v_tz, 'sick', today, today, 'rejected');
  r := pg_temp.punch(b, v_tz, 'check_in', now());
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and (select status = 'rejected' from public.requests where id = l5), 'a rejected leave is left alone', r::text);
  perform pg_temp.clean(b);
  l5 := pg_temp.mk_leave(b, v_comp, v_tz, 'annual', today + 1, today + 2);
  r := pg_temp.punch(b, v_tz, 'check_in', now());
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and pg_temp.span(l5) = (today + 1)::text || '..' || (today + 2)::text || ' d=2.0', 'a leave that starts tomorrow is left alone', pg_temp.span(l5));
  perform pg_temp.clean(b);
  update public.employee_work_schedules set is_workday = false where employee_id = b and weekday = extract(dow from today)::int;
  l5 := pg_temp.mk_leave(b, v_comp, v_tz, 'annual', today - 3, today + 3);
  r := pg_temp.punch(b, v_tz, 'check_in', now());
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and pg_temp.span(l5) = (today - 3)::text || '..' || (today + 3)::text || ' d=6.0',
                     'a day off inside the leave is not a leave day: nothing cancelled', pg_temp.span(l5));
  perform pg_temp.sched_all(b, v_comp);
  perform pg_temp.clean(b);

  -- ---------------------------------------------------------------- a leave the COMPANY granted keeps the phase 15 behaviour
  perform pg_temp.clean(b);
  insert into public.company_leave_days (company_id, name, start_date, end_date, scope) values (v_comp, 'عطلة اختبار', today, today, 'all') returning id into x;
  l5 := pg_temp.mk_leave(b, v_comp, v_tz, 'annual', today, today);
  update public.requests set company_leave_day_id = x where id = l5;
  perform pg_temp.as_user(b);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(jsonb_typeof(st -> 'leave_today') = 'null', 'a company leave day is not "your leave today" in the app', (st -> 'leave_today')::text);
  r := pg_temp.punch(b, v_tz, 'check_in', now());
  perform pg_temp.ok((r ->> 'on_approved_leave')::boolean and (r ->> 'needs_review')::boolean and not (r ->> 'leave_day_cancelled')::boolean,
                     'a punch on it is flagged for the admin as before, and the day is not cancelled', r::text);
  perform pg_temp.ok(pg_temp.span(l5) = today::text || '..' || today::text || ' d=1.0' and (select status = 'approved' from public.requests where id = l5), 'its leave is untouched');
  perform pg_temp.ok((select metadata -> 'suspect' ? 'on_approved_leave' and metadata ->> 'leave_request_id' = l5::text from public.attendance_events where id = (r ->> 'event_id')::uuid),
                     'the event carries the phase 15 reason');
  perform pg_temp.clean(b);
  delete from public.requests where company_leave_day_id = x;
  delete from public.company_leave_days where id = x;

  -- ---------------------------------------------------------------- other review reasons still apply
  perform pg_temp.clean(a);
  l6 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 1);
  r := pg_temp.punch(a, v_tz, 'check_in', now(), '{"review": true}'::jsonb);
  perform pg_temp.ok((r ->> 'needs_review')::boolean and (r ->> 'leave_day_cancelled')::boolean, 'a punch flagged for another reason is still reviewed, and still cancels the day', r::text);
  ev1 := (r ->> 'event_id')::uuid;

  -- ---------------------------------------------------------------- the admin decides: list, normal day, restore
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into q from public.admin_list_leave_day_cancellations() c where c.event_id = ev1;
  reset role;
  perform pg_temp.ok(q.event_id is not null and q.employee_id = a and q.day = today and q.leave_type = 'annual' and q.request_id = l6 and q.full_name is not null,
                     'the admin list shows the cancelled day (who, which day, which leave)', q::text);
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err('select count(*) from public.admin_list_leave_day_cancellations()');
  perform pg_temp.ok(s <> '', 'an employee cannot list them', s);
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''normal_day'')', ev1));
  reset role;
  perform pg_temp.ok(s <> '', 'an employee cannot decide', s);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''delete'')', ev1));
  perform pg_temp.ok(s = 'invalid_action', 'unknown decision refused', s);
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''normal_day'')', gen_random_uuid()));
  perform pg_temp.ok(s = 'not_found', 'unknown event refused', s);
  reset role;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (b, 'check_in', now() - interval '3 days', true, false, 'not_requested', '{}'::jsonb) returning id into evx;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''normal_day'')', evx));
  reset role;
  perform pg_temp.ok(s = 'not_leave_day_cancelled', 'an ordinary event is not a cancelled leave day', s);
  -- another company
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار قرار الإجازة', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'leave22-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (e2, 'check_in', now() - interval '1 hour', true, false, 'not_requested', jsonb_build_object('leave_day', jsonb_build_object('request_id', l6, 'day', today, 'leave_type', 'annual')))
  returning id into ev3;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''restore_leave'')', ev3));
  perform pg_temp.ok(s = 'not_found', 'another company''s event cannot be decided', s);
  perform pg_temp.ok(not exists (select 1 from public.admin_list_leave_day_cancellations() c where c.event_id = ev3), 'nor listed');
  reset role;

  -- normal day: the cancellation stands, the row leaves the list
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_decide_leave_day(ev1, 'normal_day', 'جاء للعمل');
  reset role;
  perform pg_temp.ok(r ->> 'decision' = 'normal_day', 'normal day decided', r::text);
  perform pg_temp.ok(private.approved_leave_on(a, today) is null, 'the day stays cancelled');
  perform pg_temp.ok((select metadata -> 'leave_decision' ->> 'action' = 'normal_day' and metadata -> 'leave_decision' ->> 'note' = 'جاء للعمل' from public.attendance_events where id = ev1), 'the decision is on the event');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok(not exists (select 1 from public.admin_list_leave_day_cancellations() c where c.event_id = ev1), 'it leaves the list');
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''restore_leave'')', ev1));
  reset role;
  perform pg_temp.ok(s = 'already_resolved', 'deciding twice is refused', s);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'leave.day_normal' and target_id = ev1::text) = 1, 'the audit log has the decision');

  -- restore: the day is leave again
  perform pg_temp.clean(a);
  l7 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 1);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  ev2 := (r ->> 'event_id')::uuid;
  perform pg_temp.ok(pg_temp.used(a, yr) = 1, 'before the decision: 1 day used (the day he came was cancelled)', pg_temp.used(a, yr)::text);
  delete from public.notifications where user_id = a;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_decide_leave_day(ev2, 'restore_leave', 'زيارة قصيرة');
  reset role;
  perform pg_temp.ok(r ->> 'decision' = 'restore_leave' and r ->> 'request_id' is not null, 'restore decided', r::text);
  x := (r ->> 'request_id')::uuid;
  perform pg_temp.ok(private.approved_leave_on(a, today) is not null and pg_temp.span(x) = today::text || '..' || today::text || ' d=1.0'
                     and (select status = 'approved' and leave_type = 'annual' and decided_by = v_admin from public.requests where id = x),
                     'the day is an approved leave again (its own request, decided by the admin)', pg_temp.span(x));
  perform pg_temp.ok((select count(*) from public.request_approvals where request_id = x and status = 'approved') = 1, 'with the approval history copied');
  perform pg_temp.ok(pg_temp.used(a, yr) = 2, 'the balance counts the day again', pg_temp.used(a, yr)::text);
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'request_decided' and title like 'أُعيد يوم إلى إجازتك%') = 1, 'the employee is told');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'leave.day_restored' and details ->> 'event_id' = ev2::text) = 1, 'the audit log has it');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok(not exists (select 1 from public.admin_list_leave_day_cancellations() c where c.event_id = ev2), 'it leaves the list');
  reset role;
  -- the restored day is not cancelled again by the check-out
  r := pg_temp.punch(a, v_tz, 'check_out', now() + interval '1 minute');
  perform pg_temp.ok(not (r ? 'leave_day_cancelled' and (r ->> 'leave_day_cancelled')::boolean) and private.approved_leave_on(a, today) is not null,
                     'a later punch the same day does not cancel the restored day again', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'leave.cancelled_by_punch' and details ->> 'event_id' = ev2::text) = 1, 'one cancellation only');

  -- restore a day of a ONE-day leave that was cancelled as a whole request
  perform pg_temp.clean(a);
  l7 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  ev2 := (r ->> 'event_id')::uuid;
  perform pg_temp.ok((select status = 'cancelled' from public.requests where id = l7) and pg_temp.used(a, yr) = 0, 'a one-day leave: cancelled, nothing used', pg_temp.used(a, yr)::text);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_decide_leave_day(ev2, 'restore_leave');
  reset role;
  x := (r ->> 'request_id')::uuid;
  perform pg_temp.ok(private.approved_leave_on(a, today) = x and pg_temp.used(a, yr) = 1 and (select status = 'cancelled' from public.requests where id = l7),
                     'restoring it makes a new approved one-day request; the old cancelled one stays as history', pg_temp.used(a, yr)::text);

  -- restore refused when something else already covers the day
  perform pg_temp.clean(a);
  l7 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 1);
  r := pg_temp.punch(a, v_tz, 'check_in', now());
  ev2 := (r ->> 'event_id')::uuid;
  perform pg_temp.mk_leave(a, v_comp, v_tz, 'sick', today, today);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_decide_leave_day(%L, ''restore_leave'')', ev2));
  reset role;
  perform pg_temp.ok(s = 'already_on_leave', 'restore is refused when another approved leave covers the day', s);
  perform pg_temp.ok((select metadata ? 'leave_decision' from public.attendance_events where id = ev2) is false, 'and the event stays undecided');
  perform pg_temp.clean(a);
  perform pg_temp.clean(b);
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
