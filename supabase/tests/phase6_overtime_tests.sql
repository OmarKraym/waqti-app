-- Runs inside one transaction and always ends with an exception, so nothing is kept.
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.at(d date, t text) returns timestamptz language sql as
  $$ select (d + t::time) at time zone 'Africa/Tripoli' $$;
create function pg_temp.ot(emp uuid, d date, s text, e text, dry boolean default false) returns jsonb language sql as
  $$ select public.manager_assign_overtime(gen_random_uuid(), emp, pg_temp.at(d, s), pg_temp.at(d, e), 'جرد المخزن', dry) $$;
create function pg_temp.ot_err(emp uuid, d date, s text, e text) returns text language plpgsql as $$
begin perform pg_temp.ot(emp, d, s, e, true); return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; x uuid; v_comp uuid; r jsonb; s text; v_id uuid; v_ev uuid; v_out uuid;
  v_today date := (now() at time zone 'Africa/Tripoli')::date;
  d1 date; d2 date; v_key uuid := gen_random_uuid();
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) order by employee_number offset 1 limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) order by employee_number offset 2 limit 1;
  select id into x from public.employees e where e.is_active and e.id not in (v_admin, a, b, c) order by employee_number offset 3 limit 1;
  -- A works 08:00-16:00 every day except the weekday of d2 (his day off); B manages A, C manages B
  delete from public.employee_work_schedules where employee_id = a;
  d1 := v_today + 3; d2 := v_today + 4;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time)
  select a, w, w <> extract(dow from d2)::int, case when w <> extract(dow from d2)::int then '08:00'::time end,
         case when w <> extract(dow from d2)::int then '16:00'::time end from generate_series(0, 6) w;
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_employee_manager(a, b);
  perform public.admin_set_employee_manager(b, c);
  perform public.admin_set_overtime_settings(null, null);
  delete from public.notifications;

  -- ------------------------------------------------ who may assign
  perform pg_temp.as_user(b);
  r := public.employee_overtime_overview();
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r -> 'team') t where t ->> 'id' = a::text and (t ->> 'direct')::boolean),
    'direct manager sees his employee in his team', r -> 'team' ->> 0);
  perform pg_temp.as_user(c);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(public.employee_overtime_overview() -> 'team') t where t ->> 'id' = a::text and not (t ->> 'direct')::boolean),
    'manager of the manager sees him too (not direct)');
  perform pg_temp.as_user(x);
  s := pg_temp.ot_err(a, d1, '17:00', '19:00');
  perform pg_temp.ok(s = 'not_your_team', 'someone outside the chain cannot assign', s);
  perform pg_temp.as_user(a);
  s := pg_temp.ot_err(b, d1, '17:00', '19:00');
  perform pg_temp.ok(s = 'not_your_team', 'an employee cannot assign his manager', s);
  perform pg_temp.as_user(v_admin);
  s := pg_temp.ot_err(a, d1, '17:00', '19:00');
  perform pg_temp.ok(s = 'not_your_team', 'company admin outside the chain cannot assign either', s);

  -- ------------------------------------------------ timing rules (B assigns A)
  perform pg_temp.as_user(b);
  r := pg_temp.ot(a, d1, '16:00', '18:30', true);
  perform pg_temp.ok((r ->> 'minutes')::int = 150 and (r ->> 'used_day')::int = 0, 'preview after the shift: 150 min', r::text);
  s := pg_temp.ot_err(a, d1, '15:00', '17:00');
  perform pg_temp.ok(s = 'overlaps_shift', 'cannot overlap his shift', s);
  r := pg_temp.ot(a, d1, '06:30', '08:00', true);
  perform pg_temp.ok((r ->> 'minutes')::int = 90, 'before the shift is fine');
  r := pg_temp.ot(a, d2, '09:00', '13:00', true);
  perform pg_temp.ok((r ->> 'minutes')::int = 240 and r ->> 'shift_start' is null, 'on his day off is fine (no shift)', r::text);
  s := pg_temp.ot_err(a, d1, '22:00', '23:59') || '|' || pg_temp.err(format($q$select public.manager_assign_overtime(gen_random_uuid(), %L, %L, %L)$q$, a, pg_temp.at(d1, '22:00'), pg_temp.at(d1 + 1, '01:00')));
  perform pg_temp.ok(s = '|invalid_dates', 'one calendar day per assignment (crossing midnight refused)', s);
  s := pg_temp.ot_err(a, d1, '18:00', '18:10');
  perform pg_temp.ok(s = 'invalid_duration', 'under 15 minutes refused', s);
  s := pg_temp.ot_err(a, v_today - 1, '18:00', '20:00');
  perform pg_temp.ok(s = 'invalid_dates', 'not in the past', s);

  -- ------------------------------------------------ assign, idempotency, notification
  r := public.manager_assign_overtime(v_key, a, pg_temp.at(d1, '16:30'), pg_temp.at(d1, '18:30'), 'جرد المخزن');
  v_id := (r ->> 'id')::uuid;
  perform pg_temp.ok(r ->> 'status' = 'assigned' and r ->> 'phase' = 'upcoming' and (r ->> 'minutes')::int = 120 and r -> 'assigned_by' ->> 'id' = b::text,
    'assigned at once (no approval)', r::text);
  r := public.manager_assign_overtime(v_key, a, pg_temp.at(d1, '16:30'), pg_temp.at(d1, '18:30'), 'جرد المخزن');
  perform pg_temp.ok((r ->> 'duplicate')::boolean and (select count(*) from public.overtime_assignments where employee_id = a) = 1, 'same key twice: one assignment');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'overtime_assigned') = 1
    and (select body from public.notifications where user_id = a and kind = 'overtime_assigned') like to_char(d1, 'DD/MM') || ' 16:30–18:30 · من %جرد المخزن',
    'employee notified with day, time, assigner and task', (select body from public.notifications where user_id = a));
  s := pg_temp.ot_err(a, d1, '18:00', '19:00');
  perform pg_temp.ok(s = 'overlapping_overtime', 'cannot overlap another assignment', s);

  -- ------------------------------------------------ limits (admin)
  perform pg_temp.as_user(v_admin);
  s := pg_temp.err('select public.admin_set_overtime_settings(240, 120)');
  perform pg_temp.ok(s = 'invalid_settings', 'month limit below the day limit refused', s);
  perform public.admin_set_overtime_settings(180, 300);
  perform pg_temp.ok((public.admin_get_overtime_settings() ->> 'day_minutes')::int = 180, 'admin sets limits (3 h/day, 5 h/month)');
  perform pg_temp.as_user(b);
  s := pg_temp.ot_err(a, d1, '19:00', '20:30');
  perform pg_temp.ok(s = 'overtime_day_limit', 'day limit: 120 + 90 > 180 refused', s);
  r := pg_temp.ot(a, d1, '19:00', '20:00');
  perform pg_temp.ok((r ->> 'minutes')::int = 60, 'day limit: 120 + 60 = 180 accepted');
  r := pg_temp.ot(a, d2, '09:00', '10:30', true);
  perform pg_temp.ok((r ->> 'used_month')::int = 180 and (r ->> 'limit_month')::int = 300, 'preview shows month use and limit', r::text);
  s := pg_temp.ot_err(a, d2, '09:00', '11:30');
  perform pg_temp.ok(s = 'overtime_month_limit' or date_trunc('month', d2) <> date_trunc('month', d1), 'month limit: 180 + 150 > 300 refused', s);

  -- ------------------------------------------------ leave and permissions block it
  perform pg_temp.as_user(a);
  perform public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_today + 10, v_today + 10);
  perform pg_temp.as_user(b);
  perform public.approver_decide((select (q ->> 'approval_id')::uuid from jsonb_array_elements(public.approver_inbox()) q limit 1), 'approve');
  perform pg_temp.as_user(v_admin);
  perform public.admin_decide_request((select id from public.requests where employee_id = a and status = 'pending' order by created_at desc limit 1), 'approve');
  perform pg_temp.as_user(b);
  s := pg_temp.ot_err(a, v_today + 10, '17:00', '18:00');
  perform pg_temp.ok(s = 'on_leave', 'not on an approved leave day', s);

  -- ------------------------------------------------ employee note -> assigner
  delete from public.notifications;
  perform pg_temp.as_user(a);
  r := public.employee_overtime_note(v_id, 'لدي موعد طبي في هذا الوقت');
  perform pg_temp.ok(r ->> 'employee_note' = 'لدي موعد طبي في هذا الوقت' and r ->> 'status' = 'assigned', 'employee writes a note; the assignment stays', r::text);
  perform pg_temp.ok((select count(*) from public.notifications where user_id = b and kind = 'overtime_note') = 1, 'the assigner is notified of the note');
  perform pg_temp.as_user(c);
  s := pg_temp.err(format($q$select public.employee_overtime_note(%L, 'x')$q$, v_id));
  perform pg_temp.ok(s = 'overtime_not_found', 'only the assigned employee writes the note', s);
  r := public.employee_overtime_overview();
  perform pg_temp.as_user(a);
  r := public.employee_overtime_overview();
  perform pg_temp.ok(jsonb_array_length(r -> 'mine') = 2 and (r -> 'limits' ->> 'day_minutes')::int = 180, 'employee sees his assignments and the limits', r::text);

  -- ------------------------------------------------ cancel
  delete from public.notifications;
  perform pg_temp.as_user(x);
  s := pg_temp.err(format('select public.manager_cancel_overtime(%L)', v_id));
  perform pg_temp.ok(s = 'overtime_not_found', 'outsider cannot cancel', s);
  perform pg_temp.as_user(c);
  r := public.manager_cancel_overtime(v_id);
  perform pg_temp.ok(r ->> 'status' = 'cancelled' and r ->> 'cancelled_by_name' is not null, 'manager of the manager can cancel', r::text);
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'overtime_cancelled') = 1, 'employee notified of the cancellation');
  perform pg_temp.as_user(b);
  r := pg_temp.ot(a, d1, '16:30', '18:00', true);
  perform pg_temp.ok((r ->> 'used_day')::int = 60, 'a cancelled assignment no longer counts', r::text);

  -- ------------------------------------------------ actual time from punches (an assignment that already ran)
  insert into public.overtime_assignments (company_id, employee_id, assigned_by, start_at, end_at, minutes, assign_key, created_at)
  values (v_comp, a, b, pg_temp.at(v_today - 2, '17:00'), pg_temp.at(v_today - 2, '19:00'), 120, gen_random_uuid(), now() - interval '3 days')
  returning id into v_id;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence) values (a, 'check_in', pg_temp.at(v_today - 2, '16:50'), true) returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (a, v_today - 2, v_ev, 'open');
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence)
  values (a, 'check_out', pg_temp.at(v_today - 2, '18:35'), true) returning id into v_out;
  update public.attendance_sessions set status = 'closed', check_out_event_id = v_out where employee_id = a and check_in_event_id = v_ev;
  r := private.overtime_json(v_id);
  perform pg_temp.ok((r ->> 'actual_minutes')::int = 95 and r ->> 'phase' = 'done', 'actual = punched time inside the window (17:00-18:35 = 95 min)', r::text);
  s := pg_temp.err(format('select public.manager_cancel_overtime(%L)', v_id));
  perform pg_temp.ok(s = 'overtime_started', 'cannot cancel after it started', s);

  -- ------------------------------------------------ admin list, access
  perform pg_temp.as_user(v_admin);
  r := public.admin_list_overtime((v_today - 2)::date, null);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r -> 'items') i where i ->> 'id' = v_id::text and (i ->> 'actual_minutes')::int = 95),
    'admin list of the month with actual time', r ->> 'month');
  perform pg_temp.as_user(b);
  s := pg_temp.err('select public.admin_list_overtime()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot read the admin list', s);
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err('select public.employee_overtime_overview()')
    || pg_temp.err(format($q$select public.manager_assign_overtime(gen_random_uuid(), %L, %L, %L, null, true)$q$, a, pg_temp.at(d2, '09:00'), pg_temp.at(d2, '10:00')));
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'calls work under the authenticated role', s);
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.overtime_assignments', 'select')
    and not has_function_privilege('anon', 'public.manager_assign_overtime(uuid,uuid,timestamptz,timestamptz,text,boolean)', 'execute'), 'no direct access');
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
