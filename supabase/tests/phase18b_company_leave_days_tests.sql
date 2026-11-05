-- Phase 18b: days the administration makes annual leave (for who does not check in, or for everyone), recorded once the
-- day is over, shown in the employee calendar, cancelled with the leave they created.
-- Runs inside one transaction and always ends with an exception, so nothing is kept.
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
create function pg_temp.err_as(u uuid, q text) returns text language plpgsql as $$
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q;
  reset role;
  return '';
exception when others then
  reset role;
  return sqlerrm;
end $$;
create function pg_temp.run_as(u uuid, q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q into r;
  reset role;
  return r;
end $$;
-- the leave this employee got from an administration day, on a date
create function pg_temp.got(e uuid, l uuid, d date) returns text language sql as $$
  select string_agg(r.leave_type || ':' || r.status || ':' || coalesce(r.charged_days::text, '-'), ',')
  from public.requests r
  where r.employee_id = e and r.company_leave_day_id = l and (r.start_at at time zone 'Africa/Tripoli')::date = d
$$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; v_comp uuid; r jsonb; v_today date; y int; d date; s text; l1 uuid; l2 uuid; l3 uuid; l4 uuid; n int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone 'Africa/Tripoli')::date;
  y := extract(year from v_today)::int;
  -- every day is a work day for these three; no holidays; plenty of balance by default
  delete from public.employee_work_schedules where employee_id in (a, b, c);
  delete from public.company_holidays where company_id = v_comp;
  delete from public.requests where employee_id in (a, b, c);
  update public.employees set hire_date = make_date(y - 3, 1, 1) where id in (a, b, c);
  update public.companies set created_at = make_date(y, 1, 1)::timestamp at time zone 'Africa/Tripoli' where id = v_comp;
  delete from public.notifications;

  d := v_today - 2;
  -- ---------------------------------------------------------------- for who did not check in
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'جسر العيد', %L, %L, 'absent')$q$, d, d));
  l1 := (r ->> 'id')::uuid;
  perform pg_temp.ok(r ->> 'scope' = 'absent' and not (r ->> 'applied')::boolean, 'admin adds a day: annual leave for who does not check in', r::text);
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d + time '08:00') at time zone 'Africa/Tripoli'), true, 'password', 'none');
  n := private.apply_company_leave_days(now());
  perform pg_temp.ok(pg_temp.got(a, l1, d) is null, 'who checked in keeps a normal work day', pg_temp.got(a, l1, d));
  perform pg_temp.ok(pg_temp.got(b, l1, d) = 'annual:approved:-', 'who did not check in gets one approved annual leave day', pg_temp.got(b, l1, d));
  perform pg_temp.ok((select applied_through from public.company_leave_days where id = l1) = d, 'the day is marked as recorded');
  perform private.apply_company_leave_days(now());
  update public.company_leave_days set applied_through = null where id = l1;
  perform private.apply_company_leave_days(now());
  perform pg_temp.ok((select count(*) from public.requests where employee_id = b and company_leave_day_id = l1) = 1, 'recording again never doubles the leave');
  r := private.leave_balance(b, 'annual', y);
  perform pg_temp.ok((r ->> 'used')::numeric = 1, 'the balance counts it', r::text);
  r := pg_temp.run_as(v_admin, format('select public.admin_list_requests(null, ''leave'', %L)', b));
  perform pg_temp.ok((r ->> 'total')::int = 1 and r -> 'items' -> 0 ->> 'reason' like 'إجازة سنوية من الإدارة%',
                     'the panel request list (and the report) shows the recorded leave', r::text);
  s := pg_temp.err_as(v_admin, format($q$select public.admin_save_leave_day(%L, 'جسر', %L, %L, 'all')$q$, l1, d, d));
  perform pg_temp.ok(s = 'already_applied', 'a recorded day cannot be changed (cancel it instead)', s);

  -- ---------------------------------------------------------------- for everyone: the rules for who came
  delete from public.attendance_events where employee_id = a;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', ((d - 1 + time '08:00') at time zone 'Africa/Tripoli'), true, 'password', 'none'),
         (a, 'check_in', ((d - 2 + time '08:00') at time zone 'Africa/Tripoli'), true, 'password', 'none');
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'للجميع', %L, %L, 'all', 'no_deduct')$q$, d - 1, d - 1));
  l2 := (r ->> 'id')::uuid;
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'للجميع بخصم', %L, %L, 'all', 'deduct')$q$, d - 2, d - 2));
  l3 := (r ->> 'id')::uuid;
  perform private.apply_company_leave_days(now());
  perform pg_temp.ok(pg_temp.got(a, l2, d - 1) is null and pg_temp.got(b, l2, d - 1) = 'annual:approved:-', 'everyone, "who came is not deducted"');
  perform pg_temp.ok(pg_temp.got(a, l3, d - 2) = 'annual:approved:-' and pg_temp.got(b, l3, d - 2) = 'annual:approved:-', 'everyone, "deducted even who came"');

  -- ---------------------------------------------------------------- balance too short
  insert into public.employee_leave_years (employee_id, company_id, year, entitled) values (c, v_comp, y, 0)
  on conflict (employee_id, year) do update set entitled = 0, carried = null, used_outside = 0;
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'بدون رصيد', %L, %L, 'all', 'deduct', 'unpaid')$q$, d - 3, d - 3));
  l4 := (r ->> 'id')::uuid;
  perform private.apply_company_leave_days(now());
  perform pg_temp.ok(pg_temp.got(c, l4, d - 3) = 'unpaid:approved:-', 'no balance and the rule "unpaid": unpaid leave', pg_temp.got(c, l4, d - 3));
  perform pg_temp.ok(pg_temp.got(b, l4, d - 3) = 'annual:approved:-', 'with balance: annual leave', pg_temp.got(b, l4, d - 3));
  perform pg_temp.ok(pg_temp.got(c, l3, d - 2) = 'annual:approved:-' and (private.leave_balance(c, 'annual', y) ->> 'remaining')::numeric < 0,
                     'the rule "negative": deducted and the balance goes below zero', private.leave_balance(c, 'annual', y)::text);
  -- half a day left -> half annual, the rest unpaid
  update public.employee_leave_years set entitled = null, carried = null, used_outside = 0 where employee_id = c and year = y;
  r := private.leave_balance(c, 'annual', y, null, d - 4);
  update public.employee_leave_years set used_outside = (r ->> 'remaining')::numeric - 0.5
   where employee_id = c and year = y;   -- exactly half a day left on d-4
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'نصف', %L, %L, 'all', 'deduct', 'unpaid')$q$, d - 4, d - 4));
  perform private.apply_company_leave_days(now());
  perform pg_temp.ok(pg_temp.got(c, (r ->> 'id')::uuid, d - 4) = 'annual:approved:0.5', 'half a day left: 0.5 from the balance, the rest unpaid',
                     pg_temp.got(c, (r ->> 'id')::uuid, d - 4) || ' / ' || private.leave_balance(c, 'annual', y, null, d - 4)::text);

  -- someone already on leave that day is left alone
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'لديه إجازة', %L, %L, 'all', 'deduct')$q$, d - 5, d - 5));
  insert into public.requests (employee_id, request_type, leave_type, status, start_at, end_at, days, request_key)
  values (a, 'leave', 'sick', 'approved', (d - 5)::timestamp at time zone 'Africa/Tripoli', (d - 4)::timestamp at time zone 'Africa/Tripoli', 1, gen_random_uuid());
  perform private.apply_company_leave_days(now());
  perform pg_temp.ok(pg_temp.got(a, (r ->> 'id')::uuid, d - 5) is null, 'already on leave that day: nothing added');

  -- ---------------------------------------------------------------- future day: not yet recorded, shown, no reminders
  delete from public.notifications;
  r := pg_temp.run_as(v_admin, format($q$select public.admin_save_leave_day(null, 'الخميس', %L, %L, 'all', 'deduct_overtime', 'unpaid')$q$, v_today + 3, v_today + 3));
  perform pg_temp.ok(private.leave_day_rules_text('all', 'deduct_overtime', 'unpaid') like '%عملًا إضافيًا%بدون راتب%'
                     and private.leave_day_rules_text('absent', 'no_deduct', 'negative') like '%لا يحضر%بالسالب%', 'the notice says the rules');
  perform private.apply_company_leave_days(now());
  perform pg_temp.ok((select applied_through from public.company_leave_days where id = (r ->> 'id')::uuid) is null, 'a day still to come is not recorded');
  perform pg_temp.ok(private.leave_day_on(v_comp, v_today + 3) is not null, 'reminders know it is a leave day');
  r := pg_temp.run_as(b, 'select public.employee_calendar()');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r -> 'holidays') x
                             where x ->> 'kind' = 'annual_leave' and x ->> 'name' = 'الخميس' and x ->> 'scope' = 'all'
                               and x ->> 'worked_rule' = 'deduct_overtime' and x ->> 'short_rule' = 'unpaid'),
                     'the employee sees it in the holidays card with its rules', r::text);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r -> 'holidays') x where x ->> 'name' = 'جسر العيد'), 'past days are not shown');
  insert into public.company_holidays (company_id, name, start_date, end_date) values (v_comp, 'عطلة', v_today + 9, v_today + 9);
  r := pg_temp.run_as(b, 'select public.employee_calendar()');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r -> 'holidays') x where x ->> 'kind' = 'holiday' and x ->> 'name' = 'عطلة'),
                     'official holidays come with kind "holiday"', r::text);

  -- ---------------------------------------------------------------- cancel after it was recorded: the leave goes back
  r := pg_temp.run_as(v_admin, format('select public.admin_cancel_leave_day(%L)', l1));
  perform pg_temp.ok((r ->> 'cancelled')::boolean and pg_temp.got(b, l1, d) = 'annual:cancelled:-', 'cancel: the leave it created is cancelled', r::text);
  r := pg_temp.run_as(v_admin, 'select public.admin_list_leave_days()');
  perform pg_temp.ok(jsonb_array_length(r) = 7 and (r -> -1 ->> 'cancelled')::boolean, 'the list keeps cancelled days last', r::text);

  -- validation and access
  s := pg_temp.err_as(v_admin, format($q$select public.admin_save_leave_day(null, 'x', %L, %L, 'some')$q$, v_today, v_today));
  perform pg_temp.ok(s = 'invalid_input', 'unknown scope refused', s);
  s := pg_temp.err_as(v_admin, format($q$select public.admin_save_leave_day(null, 'x', %L, %L, 'all')$q$, v_today, v_today + 40));
  perform pg_temp.ok(s = 'invalid_input', 'at most 31 days', s);
  s := pg_temp.err_as(a, format($q$select public.admin_save_leave_day(null, 'x', %L, %L, 'all')$q$, v_today, v_today));
  perform pg_temp.ok(s <> '', 'an employee cannot add one', s);
  s := pg_temp.err_as(a, 'select count(*) from public.company_leave_days');
  perform pg_temp.ok(s like 'permission denied%', 'the table is closed to the app', s);
exception when others then
  perform pg_temp.ok(false, 'stopped on an unexpected error', sqlerrm);
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
