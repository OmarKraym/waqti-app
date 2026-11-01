-- Phase 8a: punch windows. Runs inside one transaction and always ends with an exception, so nothing is kept.
-- Run with: psql -v admin_email=<company admin email> -f phase8a_punch_windows_tests.sql
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid, app jsonb default '{}') returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'app_metadata', app)::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; r jsonb; s text; w record;
  d1 date; doff date; v_ev uuid; v_sess uuid;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  -- fixed week for A: every day 08:00-16:00 except one day off (8 days ahead), so no real event is near
  d1 := (now() at time zone v_tz)::date + 7;
  doff := d1 + 1;
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, g <> extract(dow from doff)::int, case when g <> extract(dow from doff)::int then time '08:00' end,
         case when g <> extract(dow from doff)::int then time '16:00' end, v_comp
  from generate_series(0, 6) g;
  create temp table t_at (k text primary key, v timestamptz);
  insert into t_at values
    ('0659', (d1 + time '06:59') at time zone v_tz), ('0700', (d1 + time '07:00') at time zone v_tz),
    ('0729', (d1 + time '07:29') at time zone v_tz), ('0730', (d1 + time '07:30') at time zone v_tz),
    ('1000', (d1 + time '10:00') at time zone v_tz), ('1001', (d1 + time '10:01') at time zone v_tz),
    ('1359', (d1 + time '13:59') at time zone v_tz), ('1400', (d1 + time '14:00') at time zone v_tz),
    ('1700', (d1 + time '17:00') at time zone v_tz), ('1701', (d1 + time '17:01') at time zone v_tz),
    ('off1000', (doff + time '10:00') at time zone v_tz), ('off1700', (doff + time '17:00') at time zone v_tz);

  -- feature off (default) -> no limits
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '0659'));
  perform pg_temp.ok(w.allowed and w.reason = 'no_limits', 'feature off: no limits', row_to_json(w)::text);

  -- switch on with the default values (admin)
  perform pg_temp.as_user(v_admin);
  r := public.admin_set_punch_settings('off', true, 60, 120, 120, 60);
  perform pg_temp.ok((r ->> 'punch_windows_enabled')::boolean and (r ->> 'in_before_min')::int = 60, 'admin turns windows on', r::text);
  perform pg_temp.ok(exists (select 1 from public.audit_log where company_id = v_comp and action = 'company.punch_settings'), 'settings audited');
  r := public.admin_get_punch_settings();
  perform pg_temp.ok(r ->> 'biometric_policy' = 'off' and (r ->> 'out_after_min')::int = 60, 'settings read back', r::text);

  -- employee without any schedule row -> no limits
  delete from public.employee_work_schedules where employee_id = b;
  select * into w from private.punch_window(b, 'check_in', (select v from t_at where k = '0659'));
  perform pg_temp.ok(w.allowed and w.reason = 'no_limits', 'no schedule: no limits', row_to_json(w)::text);

  -- check-in edges around 08:00 (-60 / +120)
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '0700'));
  perform pg_temp.ok(w.allowed and w.reason = 'shift', 'check-in 07:00 allowed', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '0659'));
  perform pg_temp.ok(not w.allowed and w.reason = 'too_early' and w.opens_at = (select v from t_at where k = '0700')
                     and w.closes_at = (select v from t_at where k = '1000'), 'check-in 06:59 too early, opens 07:00', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '1000'));
  perform pg_temp.ok(w.allowed, 'check-in 10:00 allowed');
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '1001'));
  perform pg_temp.ok(not w.allowed and w.reason = 'too_late', 'check-in 10:01 too late', row_to_json(w)::text);

  -- check-out edges around 16:00 (-120 / +60)
  select * into w from private.punch_window(a, 'check_out', (select v from t_at where k = '1400'));
  perform pg_temp.ok(w.allowed, 'check-out 14:00 allowed');
  select * into w from private.punch_window(a, 'check_out', (select v from t_at where k = '1359'));
  perform pg_temp.ok(not w.allowed and w.reason = 'too_early', 'check-out 13:59 refused', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_out', (select v from t_at where k = '1700'));
  perform pg_temp.ok(w.allowed, 'check-out 17:00 allowed');
  select * into w from private.punch_window(a, 'check_out', (select v from t_at where k = '1701'));
  perform pg_temp.ok(not w.allowed and w.reason = 'too_late', 'check-out 17:01 refused', row_to_json(w)::text);

  -- per-employee override: in_before 30
  r := public.admin_set_employee_punch_windows(a, 30, null, null, null);
  perform pg_temp.ok(exists (select 1 from public.audit_log where action = 'employee.punch_windows' and target_id = a::text), 'override audited');
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '0730'));
  perform pg_temp.ok(w.allowed, 'override: 07:30 allowed');
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '0729'));
  perform pg_temp.ok(not w.allowed, 'override: 07:29 refused');
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = '1000'));
  perform pg_temp.ok(w.allowed, 'override: company in_after still used');
  perform pg_temp.ok((public.admin_get_employee_profile(a) -> 'punch_windows' ->> 'in_before_min')::int = 30
                     and (public.admin_get_employee_profile(a) -> 'punch_windows' ->> 'in_after_min') is null, 'profile shows override and null');
  perform public.admin_set_employee_punch_windows(a, null, null, null, null);

  -- day off, then overtime on the day off
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = 'off1000'));
  perform pg_temp.ok(not w.allowed and w.reason = 'day_off', 'day off refused', row_to_json(w)::text);
  insert into public.overtime_assignments (company_id, employee_id, assigned_by, start_at, end_at, minutes, status, assign_key)
  values (v_comp, a, v_admin, (doff + time '18:00') at time zone v_tz, (doff + time '20:00') at time zone v_tz, 120, 'assigned', gen_random_uuid());
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = 'off1700'));
  perform pg_temp.ok(w.allowed and w.reason = 'overtime', 'overtime opens a window on the day off', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_out', ((doff + time '20:30') at time zone v_tz));
  perform pg_temp.ok(w.allowed and w.reason = 'overtime', 'overtime check-out window');
  update public.overtime_assignments set status = 'cancelled', cancelled_at = now() where employee_id = a and start_at = (doff + time '18:00') at time zone v_tz;
  select * into w from private.punch_window(a, 'check_in', (select v from t_at where k = 'off1700'));
  perform pg_temp.ok(not w.allowed and w.reason = 'day_off', 'cancelled overtime: day off again', row_to_json(w)::text);

  -- shifts never cross midnight here: schedule_times_check requires end_time > start_time (see ledger ruling)
  -- a late shift 16:00-23:30: check-out window 21:30..00:30 runs past midnight into the next day
  update public.employee_work_schedules set is_workday = true, start_time = '16:00', end_time = '23:30' where employee_id = a;
  select * into w from private.punch_window(a, 'check_out', ((d1 + 1 + time '00:20') at time zone v_tz));
  perform pg_temp.ok(w.allowed and w.reason = 'shift', 'late shift: check-out 00:20 next day allowed (yesterday''s shift)', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_out', ((d1 + 1 + time '00:31') at time zone v_tz));
  perform pg_temp.ok(not w.allowed, 'late shift: 00:31 refused', row_to_json(w)::text);

  -- the punch itself is refused outside a window (today made a day off)
  update public.employee_work_schedules set is_workday = (weekday <> extract(dow from (now() at time zone v_tz))::int),
         start_time = '08:00', end_time = '16:00' where employee_id = a;
  update public.employee_work_schedules set start_time = null, end_time = null where employee_id = a and not is_workday;
  update public.employees set location_policy = 'none' where id = a;
  perform pg_temp.as_user(a);
  s := pg_temp.err(format('select public.employee_punch(%L, %L, %L)', gen_random_uuid(), 'check_in', 'not_requested'));
  perform pg_temp.ok(s = 'day_off', 'punch on a day off refused', s);
  perform pg_temp.ok(not exists (select 1 from public.attendance_events where employee_id = a), 'nothing saved');
  r := public.employee_attendance_state();
  perform pg_temp.ok((r -> 'punch_window' ->> 'allowed')::boolean = false and r -> 'punch_window' ->> 'reason' = 'day_off', 'state shows the window', (r -> 'punch_window')::text);

  -- missed check-out: open session from 3 days ago -> closed as missed_checkout, next action check-in
  update public.employee_work_schedules set is_workday = true, start_time = '08:00', end_time = '16:00' where employee_id = a;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (((now() at time zone v_tz)::date - 3) + time '08:05') at time zone v_tz, true, 'password', 'none') returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status)
  values (a, (now() at time zone v_tz)::date - 3, v_ev, 'open') returning id into v_sess;
  r := public.employee_attendance_state();
  perform pg_temp.ok(r ->> 'next_action' = 'check_in' and r -> 'open_session' = 'null'::jsonb, 'missed check-out: next action is check-in', r::text);
  perform pg_temp.ok((select status::text from public.attendance_sessions where id = v_sess) = 'missed_checkout', 'session marked missed_checkout');
  perform pg_temp.ok((select needs_review and (metadata ->> 'missed_checkout')::boolean from public.attendance_events where id = v_ev), 'check-in flagged for review');
  perform pg_temp.ok(private.overtime_actual(a, now() - interval '4 days', now()) = 0, 'missed session does not count as worked time');

  -- final review #1: a session that runs on into an open overtime window is NOT closed (overtime right after the shift)
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_employee_punch_windows(a, null, null, null, null);
  insert into public.overtime_assignments (company_id, employee_id, assigned_by, start_at, end_at, minutes, status, assign_key)
  values (v_comp, a, v_admin, (d1 + time '16:00') at time zone v_tz, (d1 + time '18:00') at time zone v_tz, 120, 'assigned', gen_random_uuid());
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (d1 + time '08:05') at time zone v_tz, true, 'password', 'none') returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (a, d1, v_ev, 'open') returning id into v_sess;
  perform pg_temp.ok(not private.close_missed_checkout(a, (d1 + time '17:30') at time zone v_tz)
                     and (select status::text from public.attendance_sessions where id = v_sess) = 'open',
                     'shift + overtime: 17:30 not closed (overtime window open)');
  perform pg_temp.ok(not private.close_missed_checkout(a, (d1 + time '19:00') at time zone v_tz), 'shift + overtime: 19:00 still inside the overtime window');
  perform pg_temp.ok(private.close_missed_checkout(a, (d1 + time '19:01') at time zone v_tz), 'shift + overtime: closed after the overtime window ends (19:01)');
  perform pg_temp.ok((select status::text from public.attendance_sessions where id = v_sess) = 'missed_checkout', 'shift + overtime: status is missed_checkout');
  -- overtime check-in at 16:30 (after an early check-out): the shift window alone ends 17:00, the overtime one 19:00
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (d1 + time '16:30') at time zone v_tz, true, 'password', 'none') returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (a, d1, v_ev, 'open') returning id into v_sess;
  perform pg_temp.ok(not private.close_missed_checkout(a, (d1 + time '17:30') at time zone v_tz), 'overtime check-in 16:30: 17:30 not closed');
  perform pg_temp.ok(private.close_missed_checkout(a, (d1 + time '19:01') at time zone v_tz), 'overtime check-in 16:30: closed at 19:01');
  -- without overtime the old rule still holds: a plain shift session closes after 17:00
  update public.overtime_assignments set status = 'cancelled', cancelled_at = now() where employee_id = a and start_at = (d1 + time '16:00') at time zone v_tz;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (d1 + time '08:10') at time zone v_tz, true, 'password', 'none') returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (a, d1, v_ev, 'open') returning id into v_sess;
  perform pg_temp.ok(not private.close_missed_checkout(a, (d1 + time '17:00') at time zone v_tz) and private.close_missed_checkout(a, (d1 + time '17:01') at time zone v_tz),
                     'plain shift: closes only after 17:00');

  -- final review #3: an approved early-leave permission opens a check-out window from the exit time; late-arrival one a check-in window
  insert into public.permission_types (company_id, name, mode, days_back, days_ahead) values (v_comp, 'tmp early', 'early_leave', 30, 30);
  insert into public.permission_types (company_id, name, mode, days_back, days_ahead) values (v_comp, 'tmp late', 'late_arrival', 30, 30);
  select * into w from private.punch_window(a, 'check_out', (d1 + time '11:30') at time zone v_tz);
  perform pg_temp.ok(not w.allowed, 'early leave: 11:30 refused without a permission', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_in', (d1 + time '12:00') at time zone v_tz);
  perform pg_temp.ok(not w.allowed, 'late arrival: 12:00 refused without a permission', row_to_json(w)::text);
  insert into public.requests (employee_id, request_type, status, start_at, end_at, company_id, permission_type_id)
  select a, 'permission', 'approved', (d1 + time '11:00') at time zone v_tz, (d1 + time '16:00') at time zone v_tz, v_comp, id
  from public.permission_types where company_id = v_comp and name = 'tmp early';
  insert into public.requests (employee_id, request_type, status, start_at, end_at, company_id, permission_type_id)
  select a, 'permission', 'approved', (d1 + time '08:00') at time zone v_tz, (d1 + time '11:30') at time zone v_tz, v_comp, id
  from public.permission_types where company_id = v_comp and name = 'tmp late';
  select * into w from private.punch_window(a, 'check_out', (d1 + time '11:30') at time zone v_tz);
  perform pg_temp.ok(w.allowed, 'early leave: 11:30 allowed with an approved permission (exit 11:00)', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_out', (d1 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(not w.allowed, 'early leave: 08:30 still refused (before exit time - out_before)', row_to_json(w)::text);
  select * into w from private.punch_window(a, 'check_in', (d1 + time '12:00') at time zone v_tz);
  perform pg_temp.ok(w.allowed, 'late arrival: 12:00 allowed with an approved permission (arrival 11:30)', row_to_json(w)::text);
  update public.requests set status = 'cancelled' where employee_id = a and request_type = 'permission' and start_at = (d1 + time '11:00') at time zone v_tz;
  select * into w from private.punch_window(a, 'check_out', (d1 + time '11:30') at time zone v_tz);
  perform pg_temp.ok(not w.allowed, 'early leave: cancelled permission opens nothing', row_to_json(w)::text);

  -- validation and access
  perform pg_temp.as_user(v_admin);
  s := pg_temp.err('select public.admin_set_punch_settings(''off'', true, 721, 120, 120, 60)');
  perform pg_temp.ok(s = 'invalid_punch_settings', '721 refused', s);
  s := pg_temp.err('select public.admin_set_punch_settings(''off'', true, -1, 120, 120, 60)');
  perform pg_temp.ok(s = 'invalid_punch_settings', '-1 refused', s);
  s := pg_temp.err('select public.admin_set_punch_settings(''maybe'', true, 60, 120, 120, 60)');
  perform pg_temp.ok(s = 'invalid_punch_settings', 'unknown policy refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_punch_windows(%L, 721, null, null, null)', a));
  perform pg_temp.ok(s = 'invalid_punch_settings', 'override 721 refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_punch_windows(%L, 10, null, null, null)', gen_random_uuid()));
  perform pg_temp.ok(s = 'employee_not_found', 'unknown / other company employee refused', s);
  perform pg_temp.as_user(a);
  s := pg_temp.err('select public.admin_set_punch_settings(''off'', false, 60, 120, 120, 60)');
  perform pg_temp.ok(s = 'forbidden', 'employee cannot change settings', s);
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.punch_window(uuid, text, timestamp with time zone)', 'execute'), 'punch_window is private');
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
