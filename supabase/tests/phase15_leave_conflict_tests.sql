-- Phase 15: a punch on an approved-leave day is saved and flagged; the admin keeps or cancels the leave.
-- Phase 22 changed how a NEW punch behaves on a leave the employee asked for (the day is cancelled, no review: see
-- phase22_leave_punch_tests.sql). Rows flagged before that still exist, so this file builds them directly (pg_temp.flag_ev) and tests
-- what the admin can do with them; the "not flagged" cases below still hold.
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
-- Every weekday is a working day (so the test does not depend on the weekday it runs on).
create function pg_temp.sched_all(p_emp uuid, p_comp uuid) returns void language plpgsql as $$
begin
  delete from public.employee_work_schedules where employee_id = p_emp;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select p_emp, g, true, '08:00', '16:00', p_comp from generate_series(0, 6) g;
end $$;
-- A leave request written directly (as the table owner) with one approved "hr" approval row, like a finished request.
create function pg_temp.mk_leave(p_emp uuid, p_comp uuid, p_tz text, p_type text, p_from date, p_to date, p_status text default 'approved')
returns uuid language plpgsql as $$
declare v uuid;
begin
  -- The leave-window trigger (phase 11) only looks at inserts: insert from today at the latest, then move the start back.
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
-- A flagged punch on a leave day, written directly (noon of that local day).
create function pg_temp.flag_ev(p_emp uuid, p_tz text, p_day date, p_leave uuid) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (p_emp, 'check_in', (p_day::timestamp + time '12:00') at time zone p_tz, true, true, 'not_requested',
          jsonb_build_object('suspect', jsonb_build_array('on_approved_leave'), 'leave_request_id', p_leave))
  returning id into v;
  return v;
end $$;
create function pg_temp.cancel_days(p_admin uuid, p_ev uuid, p_note text, p_days date[]) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(p_admin);
  set local role authenticated;
  r := public.admin_resolve_leave_conflict(p_ev, 'cancel_leave', p_note, p_days);
  reset role;
  return r;
end $$;
create function pg_temp.clean(p_emp uuid) returns void language plpgsql as $$
begin
  delete from public.attendance_sessions where employee_id = p_emp;
  delete from public.attendance_events where employee_id = p_emp;
  delete from public.requests where employee_id = p_emp;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; r jsonb; s text; today date;
  l1 uuid; l2 uuid; l3 uuid; v_ev uuid; v_ev2 uuid; v_ev3 uuid; v_ev4 uuid; n int; v_used numeric;
  v_comp2 uuid; e2 uuid; v_evx uuid; ev record;
  l4 uuid; l5 uuid; c1 uuid; c2 uuid; v_s1 uuid; v_s2 uuid; v_s3 uuid; v_s4 uuid; qr record; w int;
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

  -- ---------------------------------------------------------------- finding the leave
  l1 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 2);
  perform pg_temp.ok(private.approved_leave_on(a, today) = l1 and private.approved_leave_on(a, today + 2) = l1,
                     'an approved leave is found on its first and last day');
  perform pg_temp.ok(private.approved_leave_on(a, today + 3) is null and private.approved_leave_on(a, today - 1) is null,
                     'and not the day after it ends nor the day before it starts');

  -- ---------------------------------------------------------------- a flagged row (as phase 15 wrote it) carries the reason
  v_ev := pg_temp.flag_ev(a, v_tz, today, l1);
  perform pg_temp.ok((select metadata -> 'suspect' ? 'on_approved_leave' and metadata ->> 'leave_request_id' = l1::text and needs_review
                      from public.attendance_events where id = v_ev), 'the event carries the reason and the leave it conflicts with');

  -- the admin queue shows the leave
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into ev from public.admin_review_queue() q where q.event_id = v_ev;
  reset role;
  perform pg_temp.ok(ev.event_id is not null and ev.leave ->> 'request_id' = l1::text and ev.leave ->> 'leave_type' = 'annual'
                     and ev.leave ->> 'status' = 'approved' and (ev.leave ->> 'days')::numeric = 3
                     and ev.leave ->> 'start_date' = today::text and ev.leave ->> 'end_date' = (today + 2)::text,
                     'the queue row describes the leave (type, status, days, first and last day)', ev.leave::text);

  -- ---------------------------------------------------------------- what does NOT flag
  perform pg_temp.clean(b);
  perform pg_temp.mk_leave(b, v_comp, v_tz, 'sick', today, today, 'pending');
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and not (r ->> 'needs_review')::boolean, 'a pending leave does not flag', r::text);
  perform pg_temp.clean(b);
  perform pg_temp.mk_leave(b, v_comp, v_tz, 'sick', today, today, 'rejected');
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean, 'a rejected leave does not flag', r::text);
  perform pg_temp.clean(b);
  perform pg_temp.mk_leave(b, v_comp, v_tz, 'annual', today + 1, today + 2);
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean, 'a leave that starts tomorrow does not flag today', r::text);
  perform pg_temp.clean(b);
  perform pg_temp.mk_leave(b, v_comp, v_tz, 'annual', today - 3, today + 3);
  update public.employee_work_schedules set is_workday = false where employee_id = b and weekday = extract(dow from today)::int;
  perform pg_temp.ok(private.approved_leave_on(b, today) is null, 'a day off inside the leave range is not a conflict');
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.ok(not (r ->> 'on_approved_leave')::boolean and not (r ->> 'needs_review')::boolean, 'so a punch on that day off is normal', r::text);
  perform pg_temp.clean(b);
  perform pg_temp.sched_all(b, v_comp);
  perform pg_temp.mk_leave(b, v_comp, v_tz, 'unpaid', today, today);
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.ok((r ->> 'on_approved_leave')::boolean and (r ->> 'leave_day_cancelled')::boolean, 'an unpaid leave counts too (phase 22: its day is cancelled)', r::text);
  perform pg_temp.clean(b);
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_out', 'not_requested', null, null, null, now(), '{}'::jsonb);
  perform pg_temp.ok((r ->> 'missing_checkin')::boolean and (r ->> 'needs_review')::boolean and not (r ->> 'on_approved_leave')::boolean
                     and (select metadata -> 'suspect' ? 'missing_checkin' from public.attendance_events where id = (r ->> 'event_id')::uuid),
                     'phase 13 is intact: a check-out without a check-in is still flagged missing_checkin', r::text);
  perform pg_temp.clean(b);

  -- ---------------------------------------------------------------- permissions and wrong input
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_leave_conflict(%L, ''keep_leave'')', v_ev));
  reset role;
  perform pg_temp.ok(s <> '', 'an employee cannot resolve a leave conflict', s);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_leave_conflict(%L, ''delete'')', v_ev));
  perform pg_temp.ok(s = 'invalid_action', 'unknown decision refused', s);
  s := pg_temp.err(format('select public.admin_resolve_leave_conflict(%L, ''keep_leave'')', gen_random_uuid()));
  perform pg_temp.ok(s = 'not_found', 'unknown event refused', s);
  reset role;
  -- an event flagged for another reason is not a leave conflict
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (b, 'check_in', now() - interval '3 days', true, true, 'outside', '{}'::jsonb) returning id into v_evx;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_leave_conflict(%L, ''keep_leave'')', v_evx));
  reset role;
  perform pg_temp.ok(s = 'not_leave_conflict', 'an event flagged for another reason is not a leave conflict', s);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok((select q.leave is null from public.admin_review_queue() q where q.event_id = v_evx), 'a queue row of another kind has no leave');
  reset role;

  -- other company
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار الإجازات', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'leave-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (e2, 'check_in', now() - interval '1 hour', true, true, 'not_requested', jsonb_build_object('suspect', jsonb_build_array('on_approved_leave'), 'leave_request_id', l1))
  returning id into v_ev4;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_leave_conflict(%L, ''cancel_leave'')', v_ev4));
  reset role;
  perform pg_temp.ok(s = 'not_found', 'another company''s event cannot be resolved', s);
  perform pg_temp.ok((select status from public.requests where id = l1) = 'approved', '... and its leave is untouched');

  -- ---------------------------------------------------------------- keep the leave
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_leave_conflict(v_ev, 'keep_leave', 'حضر لإنجاز عمل عاجل');
  reset role;
  perform pg_temp.ok((select not needs_review and metadata -> 'review' ->> 'action' = 'keep_leave' and metadata -> 'review' ->> 'note' = 'حضر لإنجاز عمل عاجل'
                      from public.attendance_events where id = v_ev), 'keep_leave clears the flag and records who decided and why');
  perform pg_temp.ok((select status from public.requests where id = l1) = 'approved', 'keep_leave leaves the leave approved');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.review_keep_leave' and target_id = v_ev::text
                      and details ->> 'leave_request_id' = l1::text) = 1, 'keep_leave is in the audit log with the leave id');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_resolve_leave_conflict(%L, ''keep_leave'')', v_ev));
  reset role;
  perform pg_temp.ok(s = 'already_resolved', 'a second decision on the same event is refused', s);
  -- the same day does not flag again
  r := private.record_punch(a, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, now() + interval '2 minutes', '{}'::jsonb);
  perform pg_temp.ok(not (r ->> 'needs_review')::boolean, 'after "keep" the next punch of that day is not flagged again', r::text);

  -- ---------------------------------------------------------------- cancel the leave
  perform pg_temp.clean(a);
  delete from public.notifications where user_id = a;
  l2 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 1);
  v_used := (private.leave_balance(a, 'annual', extract(year from today)::int) ->> 'used')::numeric;
  perform pg_temp.ok(v_used = 2, 'before: the 2 leave days are counted as used', v_used::text);
  v_ev := pg_temp.flag_ev(a, v_tz, today, l2);
  -- a second flagged event of the same leave: next day, only the leave is wrong (cleared with it)
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (a, 'check_in', now() + interval '1 day', true, true, 'not_requested',
          jsonb_build_object('suspect', jsonb_build_array('on_approved_leave'), 'leave_request_id', l2)) returning id into v_ev2;
  -- and a third whose location is also wrong (stays flagged, minus the leave reason)
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (a, 'check_in', now() + interval '2 days', false, true, 'outside',
          jsonb_build_object('suspect', jsonb_build_array('on_approved_leave'), 'leave_request_id', l2)) returning id into v_ev3;

  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_leave_conflict(v_ev, 'cancel_leave', 'الموظف عاد من إجازته');
  reset role;
  perform pg_temp.ok((select status = 'cancelled' and decided_by = v_admin and decided_at is not null
                             and decision_note like '%' || today::text || '%' and decision_note like '%الموظف عاد من إجازته%'
                      from public.requests where id = l2), 'the leave is cancelled, by the admin, with the reason and the day he came', (select decision_note from public.requests where id = l2));
  perform pg_temp.ok((private.leave_balance(a, 'annual', extract(year from today)::int) ->> 'used')::numeric = 0, 'the balance returns by itself (used 2 -> 0)');
  perform pg_temp.ok((select status from public.request_approvals where request_id = l2 and step_order = 1) = 'approved',
                     'the finished approval rows stay as history');
  perform pg_temp.ok((select not needs_review and metadata -> 'review' ->> 'action' = 'cancel_leave' from public.attendance_events where id = v_ev),
                     'the punch is cleared');
  perform pg_temp.ok((select not needs_review and not (metadata -> 'suspect' ? 'on_approved_leave') from public.attendance_events where id = v_ev2),
                     'another day of the same leave, wrong only because of the leave, is cleared too');
  perform pg_temp.ok((select needs_review and not (metadata -> 'suspect' ? 'on_approved_leave') from public.attendance_events where id = v_ev3),
                     'another day that was also outside the zone stays flagged, without the leave reason');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'request_decided' and title like 'أُلغيت إجازتك%') = 1,
                     'the employee gets one notification');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'leave.cancelled_for_attendance' and target_id = l2::text
                      and details ->> 'event_id' = v_ev::text) = 1, 'the cancellation is in the audit log with the event');
  perform pg_temp.ok((r ->> 'leave_cancelled')::boolean and r ->> 'leave_request_id' = l2::text, 'the answer says the leave was cancelled', r::text);
  -- the same leave cannot flag any more, and the employee can ask for it again
  perform pg_temp.ok(private.approved_leave_on(a, today) is null, 'a cancelled leave no longer covers the day');

  -- a late event of the already cancelled leave (a race): resolving it just clears it
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, metadata)
  values (a, 'check_in', now() + interval '3 days', true, true, 'not_requested',
          jsonb_build_object('suspect', jsonb_build_array('on_approved_leave'), 'leave_request_id', l2)) returning id into v_ev4;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_leave_conflict(v_ev4, 'cancel_leave');
  reset role;
  perform pg_temp.ok(not (r ->> 'leave_cancelled')::boolean and (r ->> 'leave_already_cancelled')::boolean
                     and (select not needs_review from public.attendance_events where id = v_ev4)
                     and (select count(*) from public.notifications where user_id = a and kind = 'request_decided' and title like 'أُلغيت إجازتك%') = 1,
                     'cancelling an already cancelled leave only clears the flag (no second notice)', r::text);


  -- ---------------------------------------------------------------- cancel only some days (flexible)
  -- (1) the day he came + a duplicate in the list: the first days go, the leave shrinks, no new request
  perform pg_temp.clean(a);
  delete from public.notifications where user_id = a;
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 3);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  v_s2 := pg_temp.flag_ev(a, v_tz, today + 1, l4);
  r := pg_temp.cancel_days(v_admin, v_s1, 'عاد للعمل', array[today, today]);
  perform pg_temp.ok((select status = 'approved' and start_at = (today + 1)::timestamp at time zone v_tz
                             and end_at = (today + 4)::timestamp at time zone v_tz and days = 3
                      from public.requests where id = l4) and (select count(*) from public.requests where employee_id = a) = 1,
                     'cancelling the first day shrinks the leave in place (no new request)',
                     (select concat_ws(' ', status, start_at, end_at, days) from public.requests where id = l4));
  perform pg_temp.ok((private.leave_balance(a, 'annual', extract(year from today)::int) ->> 'used')::numeric = 3,
                     'the balance counts only the days that remain (4 -> 3)');
  perform pg_temp.ok(private.approved_leave_on(a, today) is null and private.approved_leave_on(a, today + 1) = l4,
                     'the cancelled day is no longer covered, the next one still is');
  perform pg_temp.ok((select not needs_review and metadata -> 'review' ->> 'action' = 'cancel_leave' and metadata -> 'review' -> 'days' ? today::text
                      from public.attendance_events where id = v_s1), 'the punch is cleared and the review records which days were cancelled');
  perform pg_temp.ok((select needs_review and metadata ->> 'leave_request_id' = l4::text from public.attendance_events where id = v_s2),
                     'another flagged day that is still on leave stays flagged');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'request_decided' and title = 'أُلغيت بعض أيام إجازتك'
                             and body like '%' || today::text || '%') = 1, 'the employee is told which days were cancelled (one notice)');
  perform pg_temp.ok((select decision_note like '%' || today::text || '%' and decision_note like '%عاد للعمل%' from public.requests where id = l4),
                     'the note on the request says which days and why', (select decision_note from public.requests where id = l4));
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'leave.cancelled_for_attendance' and target_id = l4::text
                             and jsonb_array_length(details -> 'cancelled_days') = 1 and not (details ->> 'whole')::boolean) = 1,
                     'the audit log lists the cancelled days and says it was not the whole leave');
  perform pg_temp.ok(not (r ->> 'leave_cancelled')::boolean and not (r ->> 'leave_already_cancelled')::boolean and (r ->> 'days_cancelled')::int = 1,
                     'the answer: not the whole leave, 1 day cancelled', r::text);

  -- (2) a day in the middle: the leave splits in two, flagged days follow their leave, the cancelled day is cleared
  perform pg_temp.clean(a);
  delete from public.notifications where user_id = a;
  l5 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 5);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l5);
  v_s2 := pg_temp.flag_ev(a, v_tz, today + 1, l5);
  v_s3 := pg_temp.flag_ev(a, v_tz, today + 2, l5);
  v_s4 := pg_temp.flag_ev(a, v_tz, today + 4, l5);
  r := pg_temp.cancel_days(v_admin, v_s1, 'يوم الورشة', array[today + 2]);
  select id into c1 from public.requests where employee_id = a and id <> l5;
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a) = 2 and c1 is not null, 'one new request is made for the later part');
  perform pg_temp.ok((select status = 'approved' and start_at = today::timestamp at time zone v_tz and end_at = (today + 2)::timestamp at time zone v_tz and days = 2
                      from public.requests where id = l5), 'the first part keeps the original request (days 0-1)');
  perform pg_temp.ok((select status = 'approved' and leave_type = 'annual' and start_at = (today + 3)::timestamp at time zone v_tz
                             and end_at = (today + 6)::timestamp at time zone v_tz and days = 3 and decided_at is not null and request_key is null
                             and decided_by is not distinct from (select decided_by from public.requests where id = l5)
                      from public.requests where id = c1), 'the later part is an approved request of the same type (days 3-5)');
  perform pg_temp.ok((private.leave_balance(a, 'annual', extract(year from today)::int) ->> 'used')::numeric = 5, 'the balance counts 5 days (6 - the 1 cancelled)');
  perform pg_temp.ok(private.approved_leave_on(a, today + 1) = l5 and private.approved_leave_on(a, today + 2) is null
                     and private.approved_leave_on(a, today + 3) = c1 and private.approved_leave_on(a, today + 5) = c1,
                     'each day is covered by its own part; the cancelled day by none');
  perform pg_temp.ok((select count(*) from public.request_approvals where request_id = c1 and status = 'approved') = 1,
                     'the finished approval is copied, so the later part still shows who approved');
  perform pg_temp.ok((select needs_review and metadata ->> 'leave_request_id' = l5::text from public.attendance_events where id = v_s2)
                     and (select needs_review and metadata ->> 'leave_request_id' = c1::text from public.attendance_events where id = v_s4),
                     'flagged days now point to the part that covers them');
  perform pg_temp.ok((select not needs_review and not (metadata -> 'suspect' ? 'on_approved_leave') from public.attendance_events where id = v_s3),
                     'the flagged event on the cancelled day is cleared');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into qr from public.admin_review_queue() x where x.event_id = v_s4;
  reset role;
  perform pg_temp.ok(qr.leave ->> 'request_id' = c1::text and (qr.leave ->> 'days')::numeric = 3 and jsonb_array_length(qr.leave -> 'working_days') = 3
                     and qr.leave -> 'working_days' ->> 0 = (today + 3)::text, 'the queue describes the part and lists its working days', qr.leave::text);
  perform pg_temp.ok(jsonb_array_length(r -> 'segments') = 2 and not (r ->> 'leave_cancelled')::boolean, 'the answer lists both parts', r::text);
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and title = 'أُلغيت بعض أيام إجازتك') = 1, 'one notice for the employee');

  -- (2b) cancel inside a part that was already split: it splits again
  r := pg_temp.cancel_days(v_admin, v_s4, null, array[today + 4]);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and status = 'approved') = 3
                     and (select days from public.requests where id = c1) = 1
                     and (private.leave_balance(a, 'annual', extract(year from today)::int) ->> 'used')::numeric = 4,
                     'a second cancellation splits the later part again (3 requests, 4 days left)');
  select id into c2 from public.requests where employee_id = a and id not in (l5, c1);
  perform pg_temp.ok(private.approved_leave_on(a, today + 3) = c1 and private.approved_leave_on(a, today + 4) is null and private.approved_leave_on(a, today + 5) = c2,
                     'days 3 and 5 are covered by their own parts, day 4 by none');

  -- (3) the last days: the leave is shortened from the end
  perform pg_temp.clean(a);
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'sick', today, today + 3);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  r := pg_temp.cancel_days(v_admin, v_s1, null, array[today + 2, today + 3]);
  perform pg_temp.ok((select start_at = today::timestamp at time zone v_tz and end_at = (today + 2)::timestamp at time zone v_tz and days = 2 and status = 'approved'
                      from public.requests where id = l4) and (select count(*) from public.requests where employee_id = a) = 1,
                     'cancelling the last days shortens the leave (no new request)');

  -- (4) listing every day = the whole leave
  perform pg_temp.clean(a);
  delete from public.notifications where user_id = a;
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 1);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  r := pg_temp.cancel_days(v_admin, v_s1, null, array[today, today + 1]);
  perform pg_temp.ok((select status = 'cancelled' from public.requests where id = l4) and (r ->> 'leave_cancelled')::boolean
                     and (select count(*) from public.notifications where user_id = a and title = 'أُلغيت إجازتك') = 1,
                     'selecting all the days cancels the whole leave (same as before)', r::text);

  -- (5) a part that starts in the past is allowed (the leave-window rule is for new requests only)
  perform pg_temp.clean(a);
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today - 30, today);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  s := pg_temp.err(format('select pg_temp.cancel_days(%L, %L, null, array[%L::date])', v_admin, v_s1, today - 20));
  perform pg_temp.ok(s = '' and (select count(*) from public.requests where employee_id = a and start_at = (today - 19)::timestamp at time zone v_tz) = 1,
                     'splitting a leave whose later part starts in the past is accepted', s);

  -- (6) wrong days are refused and nothing changes (the second day of the leave is a day off)
  perform pg_temp.clean(a);
  select extract(dow from today + 1)::int into w;
  update public.employee_work_schedules set is_workday = false where employee_id = a and weekday = w;
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 3);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  s := pg_temp.err(format('select pg_temp.cancel_days(%L, %L, null, array[%L::date])', v_admin, v_s1, today + 10));
  perform pg_temp.ok(s = 'invalid_days', 'a day outside the leave is refused', s);
  s := pg_temp.err(format('select pg_temp.cancel_days(%L, %L, null, array[%L::date])', v_admin, v_s1, today + 1));
  perform pg_temp.ok(s = 'invalid_days', 'a day off inside the leave cannot be selected', s);
  s := pg_temp.err(format('select pg_temp.cancel_days(%L, %L, null, %L::date[])', v_admin, v_s1, '{}'));
  perform pg_temp.ok(s = 'invalid_days', 'an empty list is refused', s);
  perform pg_temp.ok((select needs_review from public.attendance_events where id = v_s1) and (select days from public.requests where id = l4) = 3
                     and (select count(*) from public.requests where employee_id = a) = 1, 'after the refusals the event and the leave are untouched');

  -- (7) a run made only of days off between two cancelled days is not a part of its own
  r := pg_temp.cancel_days(v_admin, v_s1, null, array[today, today + 2]);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a) = 1
                     and (select status = 'approved' and days = 1 and start_at = (today + 3)::timestamp at time zone v_tz
                                and end_at = (today + 4)::timestamp at time zone v_tz from public.requests where id = l4),
                     'the day off left between two cancelled days makes no request with 0 days', r::text);
  -- (7b) only a day off would remain: the whole leave is cancelled
  perform pg_temp.clean(a);
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 2);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  r := pg_temp.cancel_days(v_admin, v_s1, null, array[today, today + 2]);
  perform pg_temp.ok((select status = 'cancelled' from public.requests where id = l4) and (r ->> 'leave_cancelled')::boolean
                     and (select count(*) from public.requests where employee_id = a) = 1,
                     'cancelling every working day cancels the whole leave even though a day off is left between them', r::text);
  perform pg_temp.sched_all(a, v_comp);

  -- (8) "keep" ignores the list
  perform pg_temp.clean(a);
  l4 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today + 1);
  v_s1 := pg_temp.flag_ev(a, v_tz, today, l4);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_leave_conflict(v_s1, 'keep_leave', null, array[today]);
  reset role;
  perform pg_temp.ok((select days = 2 and status = 'approved' and start_at = today::timestamp at time zone v_tz from public.requests where id = l4)
                     and (select not needs_review from public.attendance_events where id = v_s1),
                     'keep_leave leaves every day of the leave (the list is ignored)');

  -- the text of the dates in a notice: runs of days are joined
  perform pg_temp.ok(private.dates_text(array['2026-11-03', '2026-11-04', '2026-11-05', '2026-11-08', '2026-11-03']::date[]) = '2026-11-03 إلى 2026-11-05، 2026-11-08'
                     and private.dates_text(array['2026-11-03']::date[]) = '2026-11-03', 'dates_text joins consecutive days and drops duplicates',
                     private.dates_text(array['2026-11-03', '2026-11-04', '2026-11-05', '2026-11-08', '2026-11-03']::date[]));

  -- ---------------------------------------------------------------- the old "accept" still works on a leave row
  perform pg_temp.clean(a);
  l3 := pg_temp.mk_leave(a, v_comp, v_tz, 'annual', today, today);
  v_ev := pg_temp.flag_ev(a, v_tz, today, l3);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_resolve_review(v_ev, 'accept');
  reset role;
  perform pg_temp.ok((select not needs_review from public.attendance_events where id = v_ev) and (select status from public.requests where id = l3) = 'approved',
                     'the plain "accept" clears the flag and leaves the leave as it is');
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
