-- Phase 12: grace period for late arrival / early leave (marks in the attendance list; nothing is blocked).
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

do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; v_tz text; d date; doff date;
  e_in1 uuid; e_in2 uuid; e_out1 uuid; e_out2 uuid; e_in_off uuid; r jsonb; s text; row_in record; row_out record; row_in2 record;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  d := (now() at time zone v_tz)::date - 3;
  doff := d - 1;
  -- shift 08:00-16:00 every day except `doff` (day off)
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, g <> extract(dow from doff)::int, case when g <> extract(dow from doff)::int then time '08:00' end,
         case when g <> extract(dow from doff)::int then time '16:00' end, v_comp
  from generate_series(0, 6) g;

  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d + time '08:20') at time zone v_tz), true, 'password', 'none') returning id into e_in1;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_out', ((d + time '12:00') at time zone v_tz), true, 'password', 'none') returning id into e_out1;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d + time '13:00') at time zone v_tz), true, 'password', 'none') returning id into e_in2;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_out', ((d + time '15:30') at time zone v_tz), true, 'password', 'none') returning id into e_out2;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((doff + time '09:30') at time zone v_tz), true, 'password', 'none') returning id into e_in_off;

  perform pg_temp.ok((select late_grace_min = 0 and early_grace_min = 0 from public.companies where id = v_comp), 'company default is 0 / 0');
  perform pg_temp.ok(private.punch_lateness(a, e_in1, 'check_in', ((d + time '08:20') at time zone v_tz)) = 20, 'no grace: 08:20 is 20 minutes late');
  perform pg_temp.ok(private.punch_lateness(a, e_in2, 'check_in', ((d + time '13:00') at time zone v_tz)) is null, 'second check-in of the day is not an arrival');
  perform pg_temp.ok(private.punch_lateness(a, e_out1, 'check_out', ((d + time '12:00') at time zone v_tz)) is null, 'a check-out that is not the last of the day is ignored');
  perform pg_temp.ok(private.punch_lateness(a, e_out2, 'check_out', ((d + time '15:30') at time zone v_tz)) = 30, 'no grace: last check-out 15:30 is 30 minutes early');
  perform pg_temp.ok(private.punch_lateness(a, e_in_off, 'check_in', ((doff + time '09:30') at time zone v_tz)) is null, 'a day off has no late / early');

  -- admin: company default 20 / 45
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_set_grace_settings(20, 45);
  perform pg_temp.ok((r ->> 'late_grace_min')::int = 20 and (r ->> 'early_grace_min')::int = 45, 'admin saves 20 / 45', r::text);
  s := pg_temp.err('select public.admin_set_grace_settings(-1, 0)');
  perform pg_temp.ok(s = 'invalid_settings', 'negative is refused', s);
  s := pg_temp.err('select public.admin_set_grace_settings(0, 241)');
  perform pg_temp.ok(s = 'invalid_settings', 'more than 240 is refused', s);
  s := pg_temp.err('select public.admin_set_grace_settings(null, 0)');
  perform pg_temp.ok(s = 'invalid_settings', 'null is refused for the company value', s);
  reset role;
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'company.grace_settings') = 1, 'the company change is in the audit log (refused ones are not)');
  perform pg_temp.ok(private.punch_lateness(a, e_in1, 'check_in', ((d + time '08:20') at time zone v_tz)) = 0, '20 late with a grace of 20 is within the grace (0)');
  perform pg_temp.ok(private.punch_lateness(a, e_out2, 'check_out', ((d + time '15:30') at time zone v_tz)) = 0, '30 early with a grace of 45 is within the grace (0)');

  -- this employee's own values: 5 / 10 -> beyond the grace, ALL the minutes count
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_set_employee_grace(a, 5, 10);
  perform pg_temp.ok((r ->> 'late_grace_min')::int = 5 and (r ->> 'early_grace_min')::int = 10, 'admin sets 5 / 10 for one employee', r::text);
  perform pg_temp.ok((public.admin_get_employee_grace(a) ->> 'late_grace_min')::int = 5, 'admin_get_employee_grace reads it back');
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in1, 'check_in', ((d + time '08:20') at time zone v_tz)) = 20, 'own grace 5: 20 minutes late counts in full (20, not 15)');
  perform pg_temp.ok(private.punch_lateness(a, e_out2, 'check_out', ((d + time '15:30') at time zone v_tz)) = 30, 'own grace 10: 30 minutes early counts in full');

  -- the list shows the marks
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into row_in from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_in1;
  select * into row_out from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_out2;
  select * into row_in2 from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_in2;
  reset role;
  perform pg_temp.ok(row_in.late_minutes = 20 and row_in.early_minutes is null, 'list: first check-in has late_minutes 20 and no early value');
  perform pg_temp.ok(row_out.early_minutes = 30 and row_out.late_minutes is null, 'list: last check-out has early_minutes 30 and no late value');
  perform pg_temp.ok(row_in2.late_minutes is null, 'list: the second check-in has no late value');

  -- null = the company value again; 0 = an explicit "no grace" that beats the company value
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_employee_grace(a, null, null);
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in1, 'check_in', ((d + time '08:20') at time zone v_tz)) = 0, 'cleared override: back to the company value (within grace)');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_employee_grace(a, 0, 0);
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in1, 'check_in', ((d + time '08:20') at time zone v_tz)) = 20, 'own 0 beats the company 20');

  -- validation, audit, permissions
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_set_employee_grace(%L, 241, 0)', a));
  perform pg_temp.ok(s = 'invalid_settings', 'employee value above 240 is refused', s);
  s := pg_temp.err('select public.admin_set_employee_grace(gen_random_uuid(), 1, 1)');
  perform pg_temp.ok(s = 'employee_not_found', 'unknown employee', s);
  reset role;
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'employee.grace' and target_id = a::text) = 3, 'each employee change is in the audit log');
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err('select public.admin_get_grace_settings()');
  perform pg_temp.ok(s <> '', 'an employee cannot read the company setting', s);
  s := pg_temp.err(format('select public.admin_set_employee_grace(%L, 0, 0)', a));
  perform pg_temp.ok(s <> '', 'an employee cannot change his own grace', s);
  reset role;
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_set_grace_settings(integer, integer)', 'execute'), 'anon cannot call the setter');
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
