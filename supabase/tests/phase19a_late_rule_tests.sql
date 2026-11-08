-- Phase 19a: company late rule (all minutes after the grace count, or only the minutes beyond it).
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
  v_admin uuid; a uuid; v_comp uuid; v_tz text; base date; doff date; d1 date; d2 date; d3 date;
  e_in15 uuid; e_in16 uuid; e_in30 uuid; e_in_2nd uuid; e_in_off uuid; e_out10 uuid; e_out11 uuid; e_out30 uuid;
  v_other uuid; r jsonb; s text; row_in record;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  base := (now() at time zone v_tz)::date - 10;
  doff := base;                      -- the weekday of `base` is the employee's day off
  d1 := base + 1; d2 := base + 2; d3 := base + 3;   -- three working days (other weekdays)
  -- shift 08:00-16:00 every day except the weekday of `doff`
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, g <> extract(dow from doff)::int, case when g <> extract(dow from doff)::int then time '08:00' end,
         case when g <> extract(dow from doff)::int then time '16:00' end, v_comp
  from generate_series(0, 6) g;

  -- one first check-in per day (08:15, 08:16, 08:30) and one last check-out per day (15:50, 15:49, 15:30)
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d1 + time '08:15') at time zone v_tz), true, 'password', 'none') returning id into e_in15;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d1 + time '13:00') at time zone v_tz), true, 'password', 'none') returning id into e_in_2nd;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_out', ((d1 + time '15:50') at time zone v_tz), true, 'password', 'none') returning id into e_out10;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d2 + time '08:16') at time zone v_tz), true, 'password', 'none') returning id into e_in16;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_out', ((d2 + time '15:49') at time zone v_tz), true, 'password', 'none') returning id into e_out11;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d3 + time '08:30') at time zone v_tz), true, 'password', 'none') returning id into e_in30;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_out', ((d3 + time '15:30') at time zone v_tz), true, 'password', 'none') returning id into e_out30;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((doff + time '09:30') at time zone v_tz), true, 'password', 'none') returning id into e_in_off;

  perform pg_temp.ok((select late_rule from public.companies where id = v_comp) = 'all_after_grace', 'default rule is all_after_grace');

  -- company grace 15 / 10, rule = the current one: after the grace ALL the minutes count (phase 12 behaviour)
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_grace_settings(15, 10);
  r := public.admin_get_grace_settings();
  perform pg_temp.ok(r ->> 'late_rule' = 'all_after_grace' and (r ->> 'late_grace_min')::int = 15, 'getter returns late_rule with the grace values', r::text);
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in15, 'check_in', ((d1 + time '08:15') at time zone v_tz)) = 0, 'all_after_grace: 08:15 with grace 15 is 0');
  perform pg_temp.ok(private.punch_lateness(a, e_in16, 'check_in', ((d2 + time '08:16') at time zone v_tz)) = 16, 'all_after_grace: 08:16 counts all 16 minutes');
  perform pg_temp.ok(private.punch_lateness(a, e_in30, 'check_in', ((d3 + time '08:30') at time zone v_tz)) = 30, 'all_after_grace: 08:30 counts 30');
  perform pg_temp.ok(private.punch_lateness(a, e_out10, 'check_out', ((d1 + time '15:50') at time zone v_tz)) = 0, 'all_after_grace: 10 early with grace 10 is 0');
  perform pg_temp.ok(private.punch_lateness(a, e_out11, 'check_out', ((d2 + time '15:49') at time zone v_tz)) = 11, 'all_after_grace: 11 early counts all 11');

  -- the new rule: only the minutes beyond the grace
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_set_late_rule('beyond_grace');
  perform pg_temp.ok(r ->> 'late_rule' = 'beyond_grace' and (r ->> 'early_grace_min')::int = 10, 'admin sets beyond_grace and gets the settings back', r::text);
  perform pg_temp.ok(public.admin_get_grace_settings() ->> 'late_rule' = 'beyond_grace', 'getter reads it back');
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in15, 'check_in', ((d1 + time '08:15') at time zone v_tz)) = 0, 'beyond_grace: 08:15 is 0');
  perform pg_temp.ok(private.punch_lateness(a, e_in16, 'check_in', ((d2 + time '08:16') at time zone v_tz)) = 1, 'beyond_grace: 08:16 counts only 1 minute');
  perform pg_temp.ok(private.punch_lateness(a, e_in30, 'check_in', ((d3 + time '08:30') at time zone v_tz)) = 15, 'beyond_grace: 08:30 counts 15');
  perform pg_temp.ok(private.punch_lateness(a, e_out10, 'check_out', ((d1 + time '15:50') at time zone v_tz)) = 0, 'beyond_grace: 10 early is 0');
  perform pg_temp.ok(private.punch_lateness(a, e_out11, 'check_out', ((d2 + time '15:49') at time zone v_tz)) = 1, 'beyond_grace: 11 early counts only 1 (check-out follows the same rule)');
  perform pg_temp.ok(private.punch_lateness(a, e_out30, 'check_out', ((d3 + time '15:30') at time zone v_tz)) = 20, 'beyond_grace: 30 early counts 20');

  -- the attendance list shows the rule's number
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into row_in from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_in16;
  reset role;
  perform pg_temp.ok(row_in.late_minutes = 1, 'list: late_minutes follows the rule (1)');

  -- the employee's own grace (5 / 5) beats the company value under both rules
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_employee_grace(a, 5, 5);
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in15, 'check_in', ((d1 + time '08:15') at time zone v_tz)) = 10, 'beyond_grace + own grace 5: 08:15 counts 10');
  perform pg_temp.ok(private.punch_lateness(a, e_out11, 'check_out', ((d2 + time '15:49') at time zone v_tz)) = 6, 'beyond_grace + own early grace 5: 11 early counts 6');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_late_rule('all_after_grace');
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in15, 'check_in', ((d1 + time '08:15') at time zone v_tz)) = 15, 'all_after_grace + own grace 5: 08:15 counts all 15');
  perform pg_temp.ok(private.punch_lateness(a, e_out11, 'check_out', ((d2 + time '15:49') at time zone v_tz)) = 11, 'all_after_grace + own early grace 5: 11 early counts all 11');

  -- under both rules: a day off and a second check-in are not an arrival
  perform pg_temp.ok(private.punch_lateness(a, e_in_off, 'check_in', ((doff + time '09:30') at time zone v_tz)) is null, 'a day off has no lateness (all_after_grace)');
  perform pg_temp.ok(private.punch_lateness(a, e_in_2nd, 'check_in', ((d1 + time '13:00') at time zone v_tz)) is null, 'a second check-in is not an arrival (all_after_grace)');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_late_rule('beyond_grace');
  reset role;
  perform pg_temp.ok(private.punch_lateness(a, e_in_off, 'check_in', ((doff + time '09:30') at time zone v_tz)) is null, 'a day off has no lateness (beyond_grace)');
  perform pg_temp.ok(private.punch_lateness(a, e_in_2nd, 'check_in', ((d1 + time '13:00') at time zone v_tz)) is null, 'a second check-in is not an arrival (beyond_grace)');

  -- validation, permissions, isolation, audit
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err($q$select public.admin_set_late_rule('x')$q$);
  perform pg_temp.ok(s = 'invalid_settings', 'an unknown rule is refused', s);
  s := pg_temp.err($q$select public.admin_set_late_rule(null)$q$);
  perform pg_temp.ok(s = 'invalid_settings', 'null is refused', s);
  s := pg_temp.err($q$select public.admin_set_late_rule('')$q$);
  perform pg_temp.ok(s = 'invalid_settings', 'an empty rule is refused', s);
  reset role;
  perform pg_temp.ok((select late_rule from public.companies where id = v_comp) = 'beyond_grace', 'refused calls changed nothing');
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err($q$select public.admin_set_late_rule('all_after_grace')$q$);
  perform pg_temp.ok(s <> '', 'an employee cannot change the rule', s);
  reset role;
  perform pg_temp.ok((select late_rule from public.companies where id = v_comp) = 'beyond_grace', 'the employee attempt changed nothing');
  insert into public.companies (name) values ('شركة أخرى') returning id into v_other;
  perform pg_temp.ok((select late_rule from public.companies where id = v_other) = 'all_after_grace', 'another company starts on all_after_grace');
  perform pg_temp.ok((select late_rule from public.companies where id = v_other) = 'all_after_grace' and (select late_rule from public.companies where id = v_comp) = 'beyond_grace',
    'the change of company A did not touch company B');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'company.late_rule' and company_id = v_comp) = 3, 'each successful change is in the audit log (3), refused ones are not');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_set_late_rule(text)', 'execute'), 'anon cannot call the setter');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_set_late_rule(text)', 'execute'), 'authenticated can call the setter');
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
