-- Runs inside one transaction and always ends with an exception, so nothing is kept.
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
-- wall time in Tripoli -> timestamptz
create function pg_temp.at(d date, t text) returns timestamptz language sql as
  $$ select (d + t::time) at time zone 'Africa/Tripoli' $$;
-- submit a permission (dry run or real)
create function pg_temp.perm(pt uuid, s timestamptz, e timestamptz, dry boolean default false) returns jsonb language sql as
  $$ select public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, s, e, null, dry, pt) $$;
create function pg_temp.perm_err(pt uuid, s timestamptz, e timestamptz) returns text language plpgsql as $$
begin perform pg_temp.perm(pt, s, e, true); return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; v_comp uuid; v_comp2 uuid;
  t_exit uuid; t_final uuid; t_late uuid; t_mission uuid; t_new uuid;
  v_today date := (now() at time zone 'Africa/Tripoli')::date;
  v_mon date; r jsonb; ov jsonb; s text; n int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = 'omarkraym5@gmail.com';
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) order by employee_number offset 1 limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) order by employee_number offset 2 limit 1;
  -- A works every day 08:00-16:00 in these tests (whatever today is)
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time)
  select a, d, true, '08:00', '16:00' from generate_series(0, 6) d;
  v_mon := v_today + 7;  -- inside the 30-day window, and every day is a workday for A

  select id into t_exit from public.permission_types where company_id = v_comp and name = 'خروج أثناء الدوام';
  select id into t_final from public.permission_types where company_id = v_comp and name = 'خروج نهائي من الدوام';
  select id into t_late from public.permission_types where company_id = v_comp and name = 'تبرير تأخير';
  select id into t_mission from public.permission_types where company_id = v_comp and name = 'مهمة عمل';
  perform pg_temp.ok(t_exit is not null and t_final is not null and t_late is not null and t_mission is not null, 'the 4 default types exist');
  perform pg_temp.ok(not exists (select 1 from information_schema.columns where table_name = 'companies' and column_name = 'permission_minutes_per_month')
                     and to_regprocedure('public.admin_set_request_settings(integer)') is null, 'the general monthly limit is gone');

  -- start from the default paths (production may have saved ones; rolled back at the end)
  delete from public.approval_steps;
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_employee_manager(a, b);

  -- ------------------------------------------------ overview
  perform pg_temp.as_user(a);
  ov := public.employee_requests_overview();
  perform pg_temp.ok(jsonb_array_length(ov -> 'permission_types') = 4 and not (ov ? 'permission')
    and (select (x ->> 'max_per_month')::int = 3 and (x ->> 'max_minutes')::int = 120 from jsonb_array_elements(ov -> 'permission_types') x where x ->> 'name' = 'خروج أثناء الدوام'),
    'overview lists the 4 types with their limits', ov -> 'permission_types' ->> 0);

  -- ------------------------------------------------ exit during the shift: 3 / month, 120 min max
  r := pg_temp.perm(t_exit, pg_temp.at(v_mon, '10:00'), pg_temp.at(v_mon, '11:30'), true);
  perform pg_temp.ok((r ->> 'minutes')::int = 90 and (r -> 'permission' ->> 'used')::int = 0, 'exit: preview 90 min', r::text);
  s := pg_temp.perm_err(t_exit, pg_temp.at(v_mon, '10:00'), pg_temp.at(v_mon, '12:30'));
  perform pg_temp.ok(s = 'permission_too_long', 'exit: over 2 hours refused', s);
  r := pg_temp.perm(t_exit, pg_temp.at(v_mon, '09:00'), pg_temp.at(v_mon, '09:30'));
  perform pg_temp.ok(r ->> 'permission_type' = 'خروج أثناء الدوام' and r ->> 'status' = 'pending', 'exit: saved with its type name', r::text);
  perform pg_temp.perm(t_exit, pg_temp.at(v_mon, '10:00'), pg_temp.at(v_mon, '10:30'));
  perform pg_temp.perm(t_exit, pg_temp.at(v_mon, '11:00'), pg_temp.at(v_mon, '11:30'));
  s := pg_temp.perm_err(t_exit, pg_temp.at(v_mon, '12:00'), pg_temp.at(v_mon, '12:30'));
  perform pg_temp.ok(s = 'permission_limit', 'exit: 4th in the month refused (pending counts)', s);
  s := pg_temp.perm_err(t_exit, pg_temp.at(v_mon, '09:15'), pg_temp.at(v_mon, '09:45'));
  perform pg_temp.ok(s in ('permission_limit', 'overlapping_request'), 'exit: still refused', s);

  -- ------------------------------------------------ late justification: same day, 60 min max, starts at shift start
  r := pg_temp.perm(t_late, null, pg_temp.at(v_today, '08:20'), true);
  perform pg_temp.ok((r ->> 'minutes')::int = 20 and (r ->> 'start_at')::timestamptz = pg_temp.at(v_today, '08:00'),
    'late: arrival 08:20 -> 20 min from the shift start', r::text);
  s := pg_temp.perm_err(t_late, null, pg_temp.at(v_today, '07:50'));
  perform pg_temp.ok(s = 'not_late', 'late: arriving before the shift is not late', s);
  s := pg_temp.perm_err(t_late, null, pg_temp.at(v_today, '09:30'));
  perform pg_temp.ok(s = 'permission_too_long', 'late: over 1 hour refused', s);
  s := pg_temp.perm_err(t_late, null, pg_temp.at(v_today - 1, '08:20'));
  perform pg_temp.ok(s = 'outside_window', 'late: yesterday refused (same day only)', s);
  s := pg_temp.perm_err(t_late, null, pg_temp.at(v_today + 1, '08:20'));
  perform pg_temp.ok(s = 'outside_window', 'late: tomorrow refused', s);
  -- the admin can widen the window
  perform pg_temp.as_user(v_admin);
  perform public.admin_save_permission_type(t_late, 'تبرير تأخير', 'late_arrival', 3, 60, 3, 0, true, 3);
  perform pg_temp.as_user(a);
  s := pg_temp.perm_err(t_late, null, pg_temp.at(v_today - 1, '08:20'));
  perform pg_temp.ok(s = '', 'late: after the admin allows 3 days back, yesterday is accepted', s);

  -- ------------------------------------------------ final exit: ends at the shift end, 1 / month
  r := pg_temp.perm(t_final, pg_temp.at(v_mon, '14:00'), null);
  perform pg_temp.ok((r ->> 'minutes')::int = 120 and (r ->> 'end_at')::timestamptz = pg_temp.at(v_mon, '16:00'),
    'final exit at 14:00 -> ends at the shift end 16:00', r::text);
  s := pg_temp.perm_err(t_final, pg_temp.at(v_mon + 1, '13:00'), null);
  perform pg_temp.ok(s = 'permission_limit' or date_trunc('month', v_mon + 1) <> date_trunc('month', v_mon), 'final exit: 2nd in the month refused', s);
  s := pg_temp.perm_err(t_final, pg_temp.at(v_mon + 2, '16:30'), null);
  perform pg_temp.ok(s in ('invalid_dates', 'permission_limit'), 'final exit after the shift end refused', s);

  -- ------------------------------------------------ mission: no count, no time limit
  r := pg_temp.perm(t_mission, pg_temp.at(v_mon + 3, '08:00'), pg_temp.at(v_mon + 3, '15:00'), true);
  perform pg_temp.ok((r ->> 'minutes')::int = 420, 'mission: 7 hours accepted (no time limit)', r::text);

  -- ------------------------------------------------ inbox shows the requester's use of that type
  perform pg_temp.as_user(b);
  r := (select x from jsonb_array_elements(public.approver_inbox()) x where x ->> 'permission_type' = 'خروج أثناء الدوام' limit 1);
  perform pg_temp.ok((r -> 'permission' ->> 'max_per_month')::int = 3 and (r -> 'permission' ->> 'pending')::int = 2,
    'manager inbox: shows 2 other pending of this type (this one excluded) of 3', r -> 'permission' ->> 'pending');

  -- ------------------------------------------------ one path per permission type
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_approval_chain('permission', format('[{"kind":"specific_employee","approver_employee_id":"%s"},{"kind":"hr"}]', c)::jsonb, t_mission);
  r := public.admin_get_approval_chains();
  perform pg_temp.ok(jsonb_array_length(r -> 'permission_types') = 4
    and (select (x ->> 'customized')::boolean from jsonb_array_elements(r -> 'permission_types') x where x ->> 'id' = t_mission::text)
    and not (select (x ->> 'customized')::boolean from jsonb_array_elements(r -> 'permission_types') x where x ->> 'id' = t_exit::text)
    and not (r -> 'chains' ? 'permission'), 'admin: a path per permission type; only the mission one is custom', r::text);
  s := pg_temp.err($q$select public.admin_set_approval_chain('permission', '[{"kind":"hr"}]')$q$);
  perform pg_temp.ok(s = 'invalid_input', 'a permission path needs its type', s);
  perform pg_temp.as_user(a);
  r := pg_temp.perm(t_mission, pg_temp.at(v_mon + 3, '08:00'), pg_temp.at(v_mon + 3, '09:00'));
  perform pg_temp.ok(r -> 'steps' -> 0 ->> 'kind' = 'specific_employee' and r -> 'steps' -> 0 ->> 'status' = 'pending',
    'mission uses its own path (named employee first)', r::text);
  r := pg_temp.perm(t_late, null, pg_temp.at(v_today, '08:10'));
  perform pg_temp.ok(r -> 'steps' -> 0 ->> 'kind' = 'direct_manager', 'late justification keeps the default path', r::text);

  -- ------------------------------------------------ admin manages the types
  perform pg_temp.as_user(v_admin);
  t_new := public.admin_save_permission_type(null, 'إذن مراجعة طبية', 'range', 2, 180, 7, 30, true, 5);
  perform pg_temp.ok(t_new is not null and jsonb_array_length(public.admin_list_permission_types()) = 5, 'admin adds a type');
  s := pg_temp.err($q$select public.admin_save_permission_type(null, ' مهمة عمل ', 'range', null, null, 7, 30, true, 0)$q$);
  perform pg_temp.ok(s = 'name_exists', 'duplicate name refused', s);
  s := pg_temp.err($q$select public.admin_save_permission_type(null, 'x', 'whenever', null, null, 7, 30, true, 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'unknown mode refused', s);
  perform public.admin_save_permission_type(t_new, 'إذن مراجعة طبية', 'range', 2, 180, 7, 30, false, 5);
  perform pg_temp.as_user(a);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.employee_requests_overview() -> 'permission_types') x where x ->> 'id' = t_new::text),
    'a deactivated type is hidden from employees');
  s := pg_temp.perm_err(t_new, pg_temp.at(v_mon + 4, '10:00'), pg_temp.at(v_mon + 4, '11:00'));
  perform pg_temp.ok(s = 'permission_type_not_found', '...and cannot be requested', s);
  s := pg_temp.err(format($q$select public.admin_save_permission_type(%L, 'x', 'range', null, null, 7, 30, true, 0)$q$, t_exit));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot edit types', s);

  -- ------------------------------------------------ isolation, new company defaults, grants
  perform pg_temp.as_user(v_admin);
  v_comp2 := public.platform_create_company('شركة اختبار 4d', 'Africa/Tripoli');
  perform pg_temp.ok((select count(*) from public.permission_types where company_id = v_comp2) = 4, 'a new company gets the 4 default types');
  perform pg_temp.as_user(a);
  s := pg_temp.perm_err((select id from public.permission_types where company_id = v_comp2 limit 1), pg_temp.at(v_mon, '13:00'), pg_temp.at(v_mon, '13:30'));
  perform pg_temp.ok(s = 'permission_type_not_found', 'a type of another company cannot be used', s);
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err('select public.employee_requests_overview()')
    || pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, %L, %L, null, true, %L)$q$,
                          pg_temp.at(v_mon + 5, '13:00'), pg_temp.at(v_mon + 5, '14:00'), t_mission));
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'employee calls work under the authenticated role', s);
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_save_permission_type(uuid,text,text,integer,integer,integer,integer,boolean,integer)', 'execute')
    and not has_table_privilege('authenticated', 'public.permission_types', 'select')
    and not has_function_privilege('authenticated', 'private.permission_usage(uuid,uuid,date,uuid)', 'execute'), 'no direct access');
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
