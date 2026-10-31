-- Phase 4 tests. Run AFTER the phase 4 migration, in the SAME transaction, then roll back:
-- the last statement always raises (with the results), so nothing is ever saved.
-- Uses real employees of company #1 (read only, every change is rolled back).

create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
-- Runs sql and returns the error message ('' = no error).
create function pg_temp.err(q text) returns text language plpgsql as $$
begin
  execute q;
  return '';
exception when others then
  return sqlerrm;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; d uuid; e2 uuid; v_comp2 uuid;
  r jsonb; r2 jsonb; ov jsonb; inbox jsonb; v_req uuid; v_ap uuid; v_days numeric; v_tz text := 'Africa/Tripoli';
  v_today date := (now() at time zone 'Africa/Tripoli')::date;
  v_mon date; s text; n int;
begin
  -- ---------------------------------------------------------------- cast
  select u.id into v_admin from auth.users u where lower(u.email) = 'omarkraym5@gmail.com';
  select id into a from public.employees e
   where e.is_active and e.id <> v_admin and exists (select 1 from employee_work_schedules w where w.employee_id = e.id and w.is_workday)
   order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) order by employee_number offset 1 limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) order by employee_number offset 2 limit 1;
  select id into d from public.employees e where e.is_active and e.id not in (v_admin, a, b, c) order by employee_number offset 3 limit 1;
  perform pg_temp.ok(v_admin is not null and a is not null and b is not null and c is not null and d is not null, 'test cast found');
  -- next Monday as a base date for leaves (far from today's real data)
  v_mon := v_today + 21 + ((8 - extract(isodow from v_today + 21)::int) % 7);

  -- ---------------------------------------------------------------- managers
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_employee_manager(a, b);
  perform public.admin_set_employee_manager(b, c);
  perform pg_temp.ok((select manager_id from employees where id = a) = b, 'admin sets the direct manager');
  s := pg_temp.err(format('select public.admin_set_employee_manager(%L, %L)', c, a));
  perform pg_temp.ok(s = 'manager_cycle', 'manager cycle is refused (A->B->C->A)', s);
  s := pg_temp.err(format('select public.admin_set_employee_manager(%L, %L)', a, a));
  perform pg_temp.ok(s = 'manager_cycle', 'an employee cannot manage himself', s);
  perform pg_temp.as_user(a);
  s := pg_temp.err(format('select public.admin_set_employee_manager(%L, null)', a));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot set managers', s);

  -- ---------------------------------------------------------------- overview + default chain
  ov := public.employee_requests_overview();
  perform pg_temp.ok(jsonb_array_length(ov -> 'balances') >= 5 and (ov -> 'permission' ->> 'limit')::int = 240 and (ov ->> 'inbox_count')::int = 0,
    'overview: balances, permission limit 240, empty inbox', ov::text);
  perform pg_temp.as_user(v_admin);
  r := public.admin_get_approval_chains();
  perform pg_temp.ok(r -> 'chains' -> 'leave' -> 0 ->> 'kind' = 'direct_manager' and r -> 'chains' -> 'leave' -> 1 ->> 'kind' = 'hr'
    and jsonb_array_length(r -> 'customized') = 0, 'default path is direct_manager -> hr', r::text);

  -- ---------------------------------------------------------------- leave: preview, submit, idempotency, balance
  insert into employee_leave_entitlements (employee_id, leave_type, days) values (a, 'annual', 5)
    on conflict (employee_id, leave_type) do update set days = 5;
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', v_mon, v_mon + 2, null, null, 'سفر', true);
  v_days := (r ->> 'days')::numeric;
  perform pg_temp.ok((r ->> 'dry_run')::boolean and v_days between 1 and 3, 'preview computes working days without saving', r::text);
  perform pg_temp.ok(not exists (select 1 from requests where employee_id = a), 'preview saved nothing');

  r := public.employee_submit_request('44444444-4444-4444-8444-444444444444', 'leave', 'annual', v_mon, v_mon + 2, null, null, 'سفر');
  v_req := (r ->> 'id')::uuid;
  perform pg_temp.ok(r ->> 'status' = 'pending' and r -> 'steps' -> 0 ->> 'status' = 'pending' and r -> 'steps' -> 1 ->> 'kind' = 'hr'
    and r -> 'steps' -> 1 ->> 'status' = 'waiting', 'leave submitted: manager pending, hr waiting', r::text);
  r2 := public.employee_submit_request('44444444-4444-4444-8444-444444444444', 'leave', 'annual', v_mon, v_mon + 2, null, null, 'سفر');
  perform pg_temp.ok((r2 ->> 'duplicate')::boolean and r2 ->> 'id' = v_req::text and (select count(*) from requests where employee_id = a) = 1,
    'same key again returns the same request (no duplicate)');
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'sick', %L, %L)$q$, v_mon + 1, v_mon + 1));
  perform pg_temp.ok(s = 'overlapping_request', 'overlapping leave is refused', s);
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L)$q$, v_mon + 7, v_mon + 13));
  perform pg_temp.ok(s = 'insufficient_balance', 'leave above the remaining balance (pending counted) is refused', s);
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L)$q$, v_mon + 3, v_mon + 1));
  perform pg_temp.ok(s = 'invalid_dates', 'end before start is refused', s);
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L)$q$,
        make_date(extract(year from v_today)::int, 12, 30), make_date(extract(year from v_today)::int + 1, 1, 2)));
  perform pg_temp.ok(s in ('crosses_year', 'invalid_dates'), 'leave across two years is refused', s);
  -- run as the real app role (the test session itself is the owner and would bypass grants)
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err($q$insert into public.requests (employee_id, request_type, start_at, end_at) values (auth.uid(), 'other', now(), now())$q$);
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s like 'permission denied%', 'direct insert into requests is impossible (must use the function)', s);

  -- ---------------------------------------------------------------- inbox and decisions
  perform pg_temp.as_user(b);
  inbox := public.approver_inbox();
  perform pg_temp.ok(jsonb_array_length(inbox) = 1 and inbox -> 0 ->> 'id' = v_req::text and (inbox -> 0 -> 'balance' ->> 'entitled')::numeric = 5,
    'direct manager sees it in his inbox, with the balance', inbox::text);
  v_ap := (inbox -> 0 ->> 'approval_id')::uuid;
  perform pg_temp.ok((public.employee_requests_overview() ->> 'inbox_count')::int = 1, 'manager overview shows inbox count 1');
  perform pg_temp.as_user(c);
  perform pg_temp.ok(jsonb_array_length(public.approver_inbox()) = 0, 'second manager does not see it (not in the path)');
  s := pg_temp.err(format($q$select public.approver_decide(%L, 'approve')$q$, v_ap));
  perform pg_temp.ok(s = 'request_not_found', 'someone else cannot decide the step', s);
  perform pg_temp.as_user(a);
  s := pg_temp.err(format($q$select public.approver_decide(%L, 'approve')$q$, v_ap));
  perform pg_temp.ok(s = 'request_not_found', 'the requester cannot approve his own request', s);

  perform pg_temp.as_user(b);
  r := public.approver_decide(v_ap, 'approve', 'موافق');
  perform pg_temp.ok(r ->> 'status' = 'pending' and (r ->> 'current_step')::int = 2 and r -> 'steps' -> 1 ->> 'status' = 'pending',
    'manager approves -> moves to hr', r::text);
  s := pg_temp.err(format($q$select public.approver_decide(%L, 'approve')$q$, v_ap));
  perform pg_temp.ok(s in ('already_decided', 'request_not_found'), 'the same step cannot be decided twice', s);

  perform pg_temp.as_user(v_admin);
  inbox := public.approver_inbox();
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(inbox) x where x ->> 'id' = v_req::text), 'company admin sees the hr step in his inbox');
  v_ap := (select (x ->> 'approval_id')::uuid from jsonb_array_elements(inbox) x where x ->> 'id' = v_req::text);
  r := public.approver_decide(v_ap, 'approve');
  perform pg_temp.ok(r ->> 'status' = 'approved', 'hr approves -> request approved', r::text);
  perform pg_temp.as_user(a);
  ov := public.employee_requests_overview();
  perform pg_temp.ok((select (x ->> 'used')::numeric = v_days and (x ->> 'remaining')::numeric = 5 - v_days
                      from jsonb_array_elements(ov -> 'balances') x where x ->> 'leave_type' = 'annual'),
    'approved leave is deducted from the balance', ov -> 'balances' ->> 0);
  s := pg_temp.err(format('select public.employee_cancel_request(%L)', v_req));
  perform pg_temp.ok(s = 'already_decided', 'an approved request cannot be cancelled by the employee', s);

  -- ---------------------------------------------------------------- rejection + other + cancel
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'other', null, %L, %L)$q$, v_mon + 20, v_mon + 20));
  perform pg_temp.ok(s = 'reason_required', '"other" needs a reason', s);
  r := public.employee_submit_request(gen_random_uuid(), 'other', null, v_mon + 20, v_mon + 20, null, null, 'شهادة راتب');
  perform pg_temp.as_user(b);
  v_ap := (select (x ->> 'approval_id')::uuid from jsonb_array_elements(public.approver_inbox()) x where x ->> 'id' = r ->> 'id');
  r := public.approver_decide(v_ap, 'reject', 'غير مكتمل');
  perform pg_temp.ok(r ->> 'status' = 'rejected' and r ->> 'decision_note' = 'غير مكتمل' and r -> 'steps' -> 1 ->> 'status' = 'cancelled',
    'rejection ends the request; later steps cancelled', r::text);
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'sick', v_mon + 30, v_mon + 30);
  r := public.employee_cancel_request((r ->> 'id')::uuid);
  perform pg_temp.ok(r ->> 'status' = 'cancelled' and r -> 'steps' -> 0 ->> 'status' = 'cancelled', 'employee cancels a pending request', r::text);

  -- ---------------------------------------------------------------- permission (minutes, monthly limit)
  r := public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null,
         ((v_mon + 40)::timestamp + time '10:00') at time zone v_tz, ((v_mon + 40)::timestamp + time '12:00') at time zone v_tz, 'مراجعة');
  perform pg_temp.ok((r ->> 'minutes')::int = 120 and r ->> 'status' = 'pending', 'permission of 2 hours accepted', r::text);
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, %L, %L)$q$,
        ((v_mon + 41)::timestamp + time '09:00') at time zone v_tz, ((v_mon + 41)::timestamp + time '11:30') at time zone v_tz));
  perform pg_temp.ok(s = 'permission_limit' or (date_trunc('month', v_mon + 41) <> date_trunc('month', v_mon + 40) and s = ''),
    'monthly permission limit (240 min) is enforced', s);
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, %L, %L)$q$,
        ((v_mon + 42)::timestamp + time '09:00') at time zone v_tz, ((v_mon + 42)::timestamp + time '09:10') at time zone v_tz));
  perform pg_temp.ok(s = 'invalid_duration', 'permission under 15 minutes is refused', s);
  s := pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, %L, %L)$q$,
        ((v_mon + 42)::timestamp + time '22:00') at time zone v_tz, ((v_mon + 43)::timestamp + time '01:00') at time zone v_tz));
  perform pg_temp.ok(s = 'invalid_dates', 'permission across midnight is refused', s);

  -- ---------------------------------------------------------------- custom chains
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_approval_chain('permission', '[{"kind":"direct_manager"},{"kind":"second_manager"},{"kind":"hr"}]');
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null,
         ((v_mon + 50)::timestamp + time '10:00') at time zone v_tz, ((v_mon + 50)::timestamp + time '11:00') at time zone v_tz);
  perform pg_temp.ok(jsonb_array_length(r -> 'steps') = 3 and r -> 'steps' -> 1 ->> 'kind' = 'second_manager'
    and r -> 'steps' -> 1 ->> 'status' = 'waiting', 'custom 3-step path is used (manager -> manager''s manager -> hr)', r::text);
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_approval_chain('other', format('[{"kind":"direct_manager"},{"kind":"specific_employee","approver_employee_id":"%s"}]', b)::jsonb);
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'other', null, v_mon + 60, v_mon + 60, null, null, 'خطاب');
  perform pg_temp.ok(r -> 'steps' -> 1 ->> 'status' = 'skipped', 'a step repeating the previous approver is skipped', r::text);
  perform pg_temp.as_user(b);
  v_ap := (select (x ->> 'approval_id')::uuid from jsonb_array_elements(public.approver_inbox()) x where x ->> 'id' = r ->> 'id');
  r := public.approver_decide(v_ap, 'approve');
  perform pg_temp.ok(r ->> 'status' = 'approved', '...so one approval is enough', r::text);

  -- employee without a manager: manager step skipped, hr decides
  perform pg_temp.as_user(d);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_mon + 70, v_mon + 70);
  perform pg_temp.ok(r -> 'steps' -> 0 ->> 'status' = 'skipped' and r -> 'steps' -> 1 ->> 'status' = 'pending',
    'no manager set: goes straight to hr', r::text);

  -- phase 4c: the admin (HR) cannot decide a request that is still with the manager
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_mon + 80, v_mon + 80);
  perform pg_temp.as_user(v_admin);
  s := pg_temp.err(format($q$select public.admin_decide_request(%L, 'approve')$q$, r ->> 'id'));
  perform pg_temp.ok(s = 'request_not_found', 'admin cannot decide a request still at the manager step (4c)', s);
  r := public.admin_list_requests(p_status => 'pending');
  perform pg_temp.ok((r ->> 'total')::int >= 1 and not exists (select 1 from jsonb_array_elements(r -> 'items') x
                     where not exists (select 1 from jsonb_array_elements(x -> 'steps') st where st ->> 'kind' = 'hr' and st ->> 'status' = 'pending')),
    'admin lists only the pending requests that reached HR (4c)', r ->> 'total');
  perform public.admin_set_approval_chain('permission', '[]');
  perform pg_temp.ok(not exists (select 1 from approval_steps where request_type = 'permission'), 'empty path = back to default');
  s := pg_temp.err($q$select public.admin_set_approval_chain('leave', '[{"kind":"boss"}]')$q$);
  perform pg_temp.ok(s = 'invalid_input', 'unknown step kind is refused', s);

  -- ---------------------------------------------------------------- isolation (second company)
  v_comp2 := public.platform_create_company('شركة اختبار', 'Africa/Tripoli');
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'iso-test@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2;
  s := pg_temp.err(format('select public.admin_set_employee_manager(%L, %L)', a, e2));
  perform pg_temp.ok(s = 'employee_not_found', 'manager from another company is refused', s);
  s := pg_temp.err(format($q$select public.admin_set_approval_chain('leave', '[{"kind":"specific_employee","approver_employee_id":"%s"}]')$q$, e2));
  perform pg_temp.ok(s = 'employee_not_found', 'approver from another company is refused', s);
  perform pg_temp.as_user(e2);
  perform pg_temp.ok(jsonb_array_length(public.approver_inbox()) = 0, 'other company employee sees nothing');
  v_ap := (select id from request_approvals where status = 'pending' limit 1);
  s := pg_temp.err(format($q$select public.approver_decide(%L, 'approve')$q$, v_ap));
  perform pg_temp.ok(s = 'request_not_found', 'other company employee cannot decide our requests', s);

  -- ---------------------------------------------------------------- grants
  perform pg_temp.ok(not has_function_privilege('anon', 'public.employee_submit_request(uuid,text,text,date,date,timestamptz,timestamptz,text,boolean)', 'execute'),
    'anonymous users cannot submit');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.request_approvals', 'select')
    and not has_table_privilege('authenticated', 'public.requests', 'insert'), 'no direct table access for approvals / inserts');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.apply_decision(uuid,text,text,uuid,boolean)', 'execute'),
    'private decision logic is not callable by users');

  -- the same calls the app makes, under the real "authenticated" role
  perform pg_temp.as_user(a);
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err('select public.employee_requests_overview()')
    || pg_temp.err(format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', %L, %L, null, null, null, true)$q$, v_mon + 90, v_mon + 90))
    || pg_temp.err('select public.approver_inbox()');
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'employee calls work under the authenticated role', s);
  perform pg_temp.as_user(v_admin);
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err('select public.admin_get_approval_chains()') || pg_temp.err($q$select public.admin_list_requests('pending')$q$);
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'admin calls work under the authenticated role', s);
end
$tests$;

do $report$
declare v text;
begin
  select format('RESULT passed=%s failed=%s%s',
           count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;  -- always: rolls the whole run back
end
$report$;
