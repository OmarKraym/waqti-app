-- Phase 26: admin levels inside a company (hr_admin, supervisor, viewer next to the owner 'company_admin').
-- Run with: psql -v admin_email=<company admin email> -f <this file>   (supabase/local/test-db.sh runs it on a fresh copy)
-- A limited level reaches only the admin functions listed for it in private.admin_role_rpcs (default deny) and has no table access.
-- The owner keeps full access and behaves exactly as before.
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
create function pg_temp.as_user(u uuid, app jsonb default '{}') returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'app_metadata', app)::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
-- run q as the signed-in user u (role authenticated); returns the error text, '' when it worked
create function pg_temp.try_as(u uuid, q text, app jsonb default '{}') returns text language plpgsql as $$
declare s text;
begin
  perform pg_temp.as_user(u, app);
  set local role authenticated;
  s := pg_temp.err(q);
  reset role;
  return s;
end $$;
-- run a "select <jsonb expression>" as the signed-in user u (it must work) and return the result
create function pg_temp.run_as(u uuid, q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q into r;
  reset role;
  return r;
end $$;

do $tests$
declare
  v_owner uuid; a uuid; b uuid; c uuid; d uuid; e5 uuid; x uuid; v_comp uuid; v_comp2 uuid; e2 uuid;
  r jsonb; s text; rec record;
  k_pub text := 'pQECAyYgASFYIGZha2UtcHVibGljLWtleS14LWNvb3JkaW5hdGUtMzJiIlggZmFrZS1wdWJsaWMta2V5LXktY29vcmRpbmF0ZS0zMmI';
  v_viewer text[] := array['admin_get_approval_chains', 'admin_get_auto_punch_mode', 'admin_get_company_settings', 'admin_get_grace_settings',
    'admin_get_holiday_settings', 'admin_get_leave_policy', 'admin_get_leave_window', 'admin_get_overtime_settings',
    'admin_get_profile_visibility', 'admin_get_punch_settings', 'admin_list_attendance', 'admin_list_custom_kinds',
    'admin_list_employee_managers', 'admin_list_employees', 'admin_list_holidays', 'admin_list_leave_day_cancellations',
    'admin_list_leave_days', 'admin_list_missing_checkins', 'admin_list_overtime', 'admin_list_permission_types',
    'admin_list_requests', 'admin_list_work_locations', 'admin_punch_mode_preview'];
  v_super_extra text[] := array['admin_decide_leave_day', 'admin_decide_request', 'admin_dismiss_missing_checkin',
    'admin_get_employee_grace', 'admin_get_employee_kind_days', 'admin_get_leave_years', 'admin_resolve_leave_conflict',
    'admin_resolve_review', 'admin_review_queue'];
  v_hr_extra text[] := array['admin_add_punch', 'admin_get_employee_profile', 'admin_list_device_bindings', 'admin_remove_device',
    'admin_save_employee_profile', 'admin_set_employee_grace', 'admin_set_employee_kind_days', 'admin_set_employee_location_policy',
    'admin_set_employee_manager', 'admin_set_employee_punch_windows', 'admin_set_geofence', 'admin_set_leave_year',
    'admin_update_employee', 'admin_use_location_geofence'];
  -- the 12 existing functions that took one extra line; %L is the employee they act on
  v_targets text[] := array[
    'select public.admin_update_employee(%L, ''x'', null, true, false)',
    'select public.admin_save_employee_profile(%L, null, null, null, null, null, null, null, null, null, null, null, null, null, null)',
    'select public.admin_remove_device(%L)',
    'select public.admin_add_punch(%L, ''check_in'', now(), ''x'')',
    'select public.admin_set_employee_manager(%L, null)',
    'select public.admin_set_employee_grace(%L, 5, 5)',
    'select public.admin_set_employee_kind_days(%L, ''{}''::jsonb)',
    'select public.admin_set_employee_location_policy(%L, ''none'', null)',
    'select public.admin_set_employee_punch_windows(%L, null, null, null, null)',
    'select public.admin_set_geofence(%L, ''x'', 0, 0, 100)',
    'select public.admin_use_location_geofence(%L)',
    'select public.admin_set_leave_year(%L, 2026, 0, 0, 0)'];
  q text; i int;
begin
  select u.id into v_owner from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_owner;
  select id into a  from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 0 limit 1;
  select id into b  from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 1 limit 1;
  select id into c  from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 2 limit 1;
  select id into d  from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 3 limit 1;
  select id into e5 from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 4 limit 1;
  select id into x  from public.employees e where not e.is_active and e.company_id = v_comp order by employee_number limit 1;
  perform pg_temp.ok(a is not null and b is not null and c is not null and d is not null and e5 is not null and x is not null,
                     'fixture: five active employees and one inactive employee');
  delete from public.audit_log where action in ('admin.role_changed', 'admin.added', 'admin.removed');

  -- ---------------------------------------------------------------- who may call what
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_set_admin_role(uuid, text)', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_list_admin_roles()', 'execute'),
                     'signed-in users can call the two new functions (the owner check is inside)');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_set_admin_role(uuid, text)', 'execute')
                     and not has_function_privilege('anon', 'public.admin_list_admin_roles()', 'execute'),
                     'anonymous visitors cannot call them');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.limited_admin()', 'execute')
                     and not has_function_privilege('authenticated', 'private.assert_not_admin_target(uuid)', 'execute'),
                     'the two helpers are private');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'private.admin_role_rpcs', 'select')
                     and not has_table_privilege('anon', 'private.admin_role_rpcs', 'select'),
                     'the permission table is private');
  s := pg_temp.try_as(b, format('select public.admin_set_admin_role(%L, %L)', c, 'viewer'));
  perform pg_temp.ok(s = 'forbidden', 'an ordinary employee cannot set a level', s);
  s := pg_temp.try_as(b, 'select count(*) from public.admin_list_admin_roles()');
  perform pg_temp.ok(s = 'forbidden', 'an ordinary employee cannot list the levels', s);
  r := pg_temp.run_as(b, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_company_admin')::boolean and not (r ->> 'is_panel_user')::boolean
                     and r -> 'admin_role' = 'null'::jsonb and r -> 'permissions' = 'null'::jsonb and r ->> 'company_role' = 'employee',
                     'context of an ordinary employee: not a panel user, no level, no list', r::text);

  -- ---------------------------------------------------------------- the owner sets levels
  r := pg_temp.run_as(v_owner, 'select public.my_admin_context()');
  perform pg_temp.ok((r ->> 'is_company_admin')::boolean and (r ->> 'is_panel_user')::boolean and r ->> 'admin_role' = 'company_admin'
                     and r -> 'permissions' = 'null'::jsonb and r ->> 'company_role' = 'company_admin',
                     'context of the owner: full access, no permission list (null = everything)', r::text);
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', a, 'hr_admin'));
  perform pg_temp.ok(r ->> 'role' = 'hr_admin' and r ->> 'previous' = 'employee' and r ->> 'employee_id' = a::text
                     and r ->> 'full_name' = (select e.full_name from public.employees e where e.id = a), 'owner makes A an hr_admin', r::text);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', b, 'supervisor'));
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', c, 'viewer'));
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = a) = 'hr_admin'
                     and (select m.role from public.company_members m where m.user_id = b) = 'supervisor'
                     and (select m.role from public.company_members m where m.user_id = c) = 'viewer', 'the roles are stored');
  perform pg_temp.ok((select count(*) from public.audit_log where company_id = v_comp and action = 'admin.role_changed' and actor_id = v_owner) = 3
                     and not exists (select 1 from public.audit_log where company_id = v_comp and action in ('admin.added', 'admin.removed')),
                     'three level changes audited, and no owner record for a limited level');
  select l.details into rec from public.audit_log l where l.action = 'admin.role_changed' and l.target_id = a::text;
  perform pg_temp.ok(rec.details ->> 'from' = 'employee' and rec.details ->> 'to' = 'hr_admin'
                     and rec.details ->> 'employee_number' = (select e.employee_number from public.employees e where e.id = a),
                     'the audit row says from, to and the employee number', rec.details::text);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', d, 'boss'));
  perform pg_temp.ok(s = 'invalid_role', 'an unknown level is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, null)', d));
  perform pg_temp.ok(s = 'invalid_role', 'a missing level is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', v_owner, 'viewer'));
  perform pg_temp.ok(s = 'cannot_change_self', 'nobody changes his own level', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', gen_random_uuid(), 'viewer'));
  perform pg_temp.ok(s = 'not_found', 'an unknown employee is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', a, 'hr_admin'));
  perform pg_temp.ok(s = 'no_change', 'the same level again is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', x, 'viewer'));
  perform pg_temp.ok(s = 'employee_inactive', 'an inactive employee cannot be given a level', s);
  r := pg_temp.run_as(v_owner, 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from public.admin_list_admin_roles() q');
  perform pg_temp.ok(jsonb_array_length(r) = 4
                     and (r -> 0 ->> 'role') = 'company_admin' and (r -> 0 ->> 'is_me')::boolean
                     and exists (select 1 from jsonb_array_elements(r) j where j ->> 'id' = c::text and j ->> 'role' = 'viewer' and j ->> 'email' is not null),
                     'the list: the owner first, then the three levels, with e-mail', left(r::text, 300));

  -- ---------------------------------------------------------------- the context of a limited level
  r := pg_temp.run_as(c, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_company_admin')::boolean and (r ->> 'is_panel_user')::boolean and r ->> 'admin_role' = 'viewer'
                     and jsonb_typeof(r -> 'permissions') = 'array' and r -> 'permissions' ? 'admin_list_requests'
                     and not r -> 'permissions' ? 'admin_decide_request' and r ->> 'company_role' = 'viewer',
                     'viewer context: panel user, not owner, with his permission list', left(r::text, 200));
  r := pg_temp.run_as(a, 'select public.my_admin_context()');
  perform pg_temp.ok(r ->> 'admin_role' = 'hr_admin' and r -> 'permissions' ? 'admin_get_employee_profile'
                     and r -> 'permissions' ? 'admin_decide_request' and r -> 'permissions' ? 'admin_list_requests'
                     and not r -> 'permissions' ? 'admin_set_company_name',
                     'hr_admin context: his list includes the supervisor and viewer lists, not the owner-only ones');

  -- ---------------------------------------------------------------- viewer (C): reads, nothing else
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = '', 'viewer: list requests', s);
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_employees()');
  perform pg_temp.ok(s = '', 'viewer: list employees', s);
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_attendance()');
  perform pg_temp.ok(s = '', 'viewer: list attendance', s);
  s := pg_temp.try_as(c, 'select public.admin_get_company_settings()');
  perform pg_temp.ok(s = '', 'viewer: read the company settings', s);
  s := pg_temp.try_as(c, 'select public.admin_list_overtime(date_trunc(''month'', now())::date, null)');
  perform pg_temp.ok(s = '', 'viewer: read overtime', s);
  s := pg_temp.try_as(c, format('select public.admin_decide_request(%L, %L, null, null)', gen_random_uuid(), 'approved'));
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot decide a request', s);
  s := pg_temp.try_as(c, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'viewer: the review queue is for supervisors', s);
  s := pg_temp.try_as(c, format('select public.admin_get_employee_profile(%L)', a));
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot read a profile (it holds the salary)', s);
  s := pg_temp.try_as(c, 'select public.admin_set_company_name(''x'')');
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot rename the company', s);
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_admins()');
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot list the owners', s);
  s := pg_temp.try_as(c, format('select public.admin_set_admin_role(%L, %L)', d, 'viewer'));
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot set levels', s);
  s := pg_temp.try_as(c, format('select public.admin_add_admin(%L)', d));
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot make an owner', s);
  s := pg_temp.try_as(c, 'select public.admin_set_auto_punch_mode(true)');
  perform pg_temp.ok(s = 'forbidden', 'viewer: cannot change the automatic punch mode', s);
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_deduction_policies()');
  perform pg_temp.ok(s = 'forbidden', 'viewer: no payroll policies', s);
  -- no table access either: a direct read returns only his own row
  r := pg_temp.run_as(c, 'select to_jsonb((select count(*) from public.employees))');
  perform pg_temp.ok(r = '1'::jsonb, 'viewer: a direct table read returns only his own row', r::text);
  s := pg_temp.try_as(c, 'select public.employee_attendance_state()');
  perform pg_temp.ok(s = '', 'a viewer is still an employee: his own punch state works', s);

  -- ---------------------------------------------------------------- supervisor (B): reads + decisions
  s := pg_temp.try_as(b, format('select public.admin_decide_request(%L, %L, null, null)', gen_random_uuid(), 'approved'));
  perform pg_temp.ok(s <> 'forbidden' and s <> '', 'supervisor: the gate opens for a decision (the request itself is not found)', s);
  s := pg_temp.try_as(b, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = '', 'supervisor: the review queue', s);
  s := pg_temp.try_as(b, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = '', 'supervisor: list requests', s);
  s := pg_temp.try_as(b, format('select public.admin_get_employee_profile(%L)', d));
  perform pg_temp.ok(s = 'forbidden', 'supervisor: cannot read a profile', s);
  s := pg_temp.try_as(b, format('select public.admin_add_punch(%L, %L, now(), %L)', d, 'check_in', 'x'));
  perform pg_temp.ok(s = 'forbidden', 'supervisor: cannot add a manual punch', s);
  s := pg_temp.try_as(b, format('select public.admin_cancel_leave_day(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'forbidden', 'supervisor: cannot cancel a company leave day (it cancels the approved leave of everyone tied to it)', s);
  s := pg_temp.try_as(a, format('select public.admin_cancel_leave_day(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot cancel a company leave day either', s);
  s := pg_temp.try_as(b, format('select public.admin_update_employee(%L, %L, null, true, false)', d, 'x'));
  perform pg_temp.ok(s = 'forbidden', 'supervisor: cannot edit an employee', s);

  -- ---------------------------------------------------------------- hr_admin (A): employees, not company-wide settings
  s := pg_temp.try_as(a, format('select public.admin_get_employee_profile(%L)', d));
  perform pg_temp.ok(s = '', 'hr_admin: reads a profile', s);
  s := pg_temp.try_as(a, format('select public.admin_update_employee(%L, %L, null, true, %L)', d, 'موظف معدّل',
                                (select e.geofence_required from public.employees e where e.id = d)));
  perform pg_temp.ok(s = '', 'hr_admin: edits an ordinary employee', s);
  perform pg_temp.ok((select e.full_name from public.employees e where e.id = d) = 'موظف معدّل', '... and the edit is saved');
  s := pg_temp.try_as(a, format('select public.admin_decide_request(%L, %L, null, null)', gen_random_uuid(), 'approved'));
  perform pg_temp.ok(s <> 'forbidden' and s <> '', 'hr_admin: the gate opens for a decision too', s);
  s := pg_temp.try_as(a, 'select public.admin_set_company_settings(''x'', ''y'', 1)');
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot change company settings', s);
  s := pg_temp.try_as(a, 'select public.admin_set_punch_settings(''off'', false, 60, 120, 120, 60)');
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot change punch settings', s);
  s := pg_temp.try_as(a, 'select public.admin_set_company_name(''x'')');
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot rename the company', s);
  s := pg_temp.try_as(a, format('select public.admin_delete_employee(%L, %L)', d, 'x'));
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot delete an employee', s);
  s := pg_temp.try_as(a, format('select public.admin_set_admin_role(%L, %L)', d, 'viewer'));
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot set levels', s);
  s := pg_temp.try_as(a, format('select public.admin_add_admin(%L)', d));
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot make an owner', s);
  s := pg_temp.try_as(a, format('select public.admin_remove_admin(%L)', v_owner));
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot remove an owner', s);
  s := pg_temp.try_as(a, 'select count(*) from public.admin_list_admin_roles()');
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: cannot list the levels', s);
  s := pg_temp.try_as(a, 'select count(*) from public.admin_list_deduction_policies()');
  perform pg_temp.ok(s = 'forbidden', 'hr_admin: no payroll policies', s);
  s := pg_temp.try_as(a, 'select public.employee_attendance_state()');
  perform pg_temp.ok(s = '', 'an admin level does not stop him from using the employee app', s);

  -- ---------------------------------------------------------------- a limited level never touches an account that holds an admin level
  for i in 1 .. array_length(v_targets, 1) loop
    q := v_targets[i];
    s := pg_temp.try_as(a, format(q, v_owner));
    perform pg_temp.ok(s = 'forbidden', format('hr_admin cannot reach an owner (function %s of %s)', i, array_length(v_targets, 1)), s);
    s := pg_temp.try_as(a, format(q, b));
    perform pg_temp.ok(s = 'forbidden', format('hr_admin cannot reach a supervisor (function %s)', i), s);
    s := pg_temp.try_as(a, format(q, a));
    perform pg_temp.ok(s = 'forbidden', format('hr_admin cannot reach himself (function %s)', i), s);
    s := pg_temp.try_as(a, format(q, d));
    perform pg_temp.ok(s is distinct from 'forbidden', format('hr_admin passes the gate for an ordinary employee (function %s)', i), s);
    s := pg_temp.try_as(v_owner, format(q, b));
    perform pg_temp.ok(s is distinct from 'forbidden', format('the owner is not restricted (function %s)', i), s);
  end loop;

  -- ---------------------------------------------------------------- default deny, fail closed
  create function public.admin_zz_new_function() returns uuid language plpgsql security definer set search_path = '' as
    $f$ declare v uuid := public.require_company_admin(); begin return v; end $f$;
  grant execute on function public.admin_zz_new_function() to authenticated;
  s := pg_temp.try_as(a, 'select public.admin_zz_new_function()');
  perform pg_temp.ok(s = 'forbidden', 'a new admin function is closed to every limited level until it is listed', s);
  s := pg_temp.try_as(v_owner, 'select public.admin_zz_new_function()');
  perform pg_temp.ok(s = '', 'the owner reaches a new admin function as before', s);
  insert into private.admin_role_rpcs (role, rpc) values ('viewer', 'admin_zz_new_function');
  s := pg_temp.try_as(c, 'select public.admin_zz_new_function()');
  perform pg_temp.ok(s = '', 'one insert opens a function to a level (no code change)', s);
  s := pg_temp.try_as(a, 'select public.admin_zz_new_function()');
  perform pg_temp.ok(s = 'forbidden', '... and only to that level', s);
  delete from private.admin_role_rpcs where rpc = 'admin_zz_new_function';
  perform pg_temp.as_user(a);
  s := pg_temp.err('select public.require_company_admin()');
  perform pg_temp.ok(s = 'forbidden', 'called straight (no admin function on the stack): closed to a limited level', s);
  perform pg_temp.as_user(v_owner);
  s := pg_temp.err('select public.require_company_admin()');
  perform pg_temp.ok(s = '', 'called straight: the owner passes', s);
  perform pg_temp.as_user(b);
  s := pg_temp.err('select public.require_company_admin()');
  perform pg_temp.ok(s = 'forbidden', 'called straight: a supervisor is closed too', s);
  -- the temporary-password rule applies to every level
  s := pg_temp.try_as(a, 'select count(*) from public.admin_list_employees()', '{"must_change_password": true}');
  perform pg_temp.ok(s = 'must_change_password', 'an admin level with a temporary password is stopped', s);
  s := pg_temp.try_as(v_owner, 'select count(*) from public.admin_list_employees()', '{"must_change_password": true}');
  perform pg_temp.ok(s = 'must_change_password', 'the owner with a temporary password is stopped, as before', s);

  -- ---------------------------------------------------------------- the permission data itself
  perform pg_temp.ok((select array_agg(rpc order by rpc) from private.admin_role_rpcs where role = 'viewer') = v_viewer, 'viewer list is exactly the agreed list',
                     (select array_agg(rpc order by rpc)::text from private.admin_role_rpcs where role = 'viewer'));
  perform pg_temp.ok((select array_agg(rpc order by rpc) from private.admin_role_rpcs where role = 'supervisor')
                     = (select array_agg(u order by u) from unnest(v_viewer || v_super_extra) u), 'supervisor list = viewer list + decisions');
  perform pg_temp.ok((select array_agg(rpc order by rpc) from private.admin_role_rpcs where role = 'hr_admin')
                     = (select array_agg(u order by u) from unnest(v_viewer || v_super_extra || v_hr_extra) u), 'hr_admin list = supervisor list + employee administration');
  perform pg_temp.ok(not exists (select 1 from private.admin_role_rpcs r
                                 where not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                                                   where ns.nspname = 'public' and p.proname = r.rpc)),
                     'every listed function exists (a rename cannot leave a dead entry)',
                     (select string_agg(r.rpc, ',') from private.admin_role_rpcs r
                      where not exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = r.rpc)));
  perform pg_temp.ok(not exists (select 1 from private.admin_role_rpcs r where r.role = 'viewer'
                                 and r.rpc not like 'admin\_list\_%' and r.rpc not like 'admin\_get\_%' and r.rpc <> 'admin_punch_mode_preview'),
                     'viewer has nothing that writes');
  perform pg_temp.ok(not exists (select 1 from private.admin_role_rpcs r where r.rpc = any (array[
      'admin_set_admin_role', 'admin_list_admin_roles', 'admin_add_admin', 'admin_remove_admin', 'admin_list_admins', 'admin_delete_employee',
      'admin_set_company_name', 'admin_set_company_settings', 'admin_set_punch_settings', 'admin_set_auto_punch_mode',
      'admin_save_deduction_policy', 'admin_delete_deduction_policy', 'admin_list_deduction_policies', 'admin_preview_deduction',
      'admin_set_late_rule', 'admin_set_leave_policy', 'admin_set_leave_window', 'admin_set_overtime_settings', 'admin_set_grace_settings',
      'admin_set_holiday_settings', 'admin_set_profile_visibility', 'admin_set_approval_chain', 'admin_add_work_location',
      'admin_delete_work_location', 'admin_set_location_geofence', 'admin_cancel_leave_day', 'admin_save_leave_day',
      'admin_save_holiday', 'admin_delete_holiday', 'admin_save_permission_type', 'admin_save_custom_kind', 'admin_delete_custom_kind'])),
                     'the owner-only functions are in no limited level',
                     (select string_agg(r.rpc, ',') from private.admin_role_rpcs r where r.rpc in ('admin_set_company_name', 'admin_add_admin', 'admin_set_admin_role', 'admin_cancel_leave_day')));

  -- ---------------------------------------------------------------- taking a level away works at once
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', c, 'employee'));
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = 'forbidden', 'after the level is taken away: closed at once (no new sign-in needed)', s);
  r := pg_temp.run_as(c, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_panel_user')::boolean and r -> 'admin_role' = 'null'::jsonb and r -> 'permissions' = 'null'::jsonb,
                     'context after removal: not a panel user', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'admin.role_changed' and target_id = c::text and details ->> 'to' = 'employee') = 1,
                     'the removal is audited');
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', c, 'viewer'));
  update public.employees set is_active = false where id = c;
  s := pg_temp.try_as(c, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = 'forbidden', 'an inactive employee with a level is closed', s);
  r := pg_temp.run_as(c, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_panel_user')::boolean and r -> 'admin_role' = 'null'::jsonb, 'an inactive employee: not a panel user', r::text);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', c, 'employee'));
  perform pg_temp.ok(s = '', 'the owner can still take the level away from an inactive employee', s);
  update public.employees set is_active = true where id = c;

  -- ---------------------------------------------------------------- owners: promote, demote, keep the phase 16 records true
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', d, 'company_admin'));
  perform pg_temp.ok(r ->> 'role' = 'company_admin' and r ->> 'previous' = 'employee', 'owner makes D an owner', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'admin.added' and target_id = d::text and actor_id = v_owner) = 1,
                     'an owner promotion also writes the phase 16 record admin.added');
  r := pg_temp.run_as(v_owner, 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from public.admin_list_admins() q');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r) j where j ->> 'id' = d::text), 'D is in the phase 16 admin list too');
  r := pg_temp.run_as(d, 'select public.my_admin_context()');
  perform pg_temp.ok((r ->> 'is_company_admin')::boolean and r ->> 'admin_role' = 'company_admin', 'D is an owner at once', r::text);
  r := pg_temp.run_as(d, format('select public.admin_set_admin_role(%L, %L)', v_owner, 'viewer'));
  perform pg_temp.ok(r ->> 'previous' = 'company_admin' and r ->> 'role' = 'viewer', 'one owner may demote another', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'admin.removed' and target_id = v_owner::text and actor_id = d) = 1,
                     'an owner demotion also writes the phase 16 record admin.removed');
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', d, 'viewer'));
  perform pg_temp.ok(s = 'forbidden', 'the demoted owner is a viewer now and cannot demote D', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_update_employee(%L, %L, null, false, false)', d, 'x'));
  perform pg_temp.ok(s = 'forbidden', '... and cannot deactivate D', s);
  s := pg_temp.try_as(d, format('select public.admin_set_admin_role(%L, %L)', d, 'viewer'));
  perform pg_temp.ok(s = 'cannot_change_self', 'the only working owner cannot demote himself', s);
  perform pg_temp.run_as(d, format('select public.admin_set_admin_role(%L, %L)', v_owner, 'company_admin'));
  perform pg_temp.ok(private.working_admin_count(v_comp, null) = 2, 'both are owners again');

  -- ---------------------------------------------------------------- phone alone never signs in an admin level; delete needs the level removed
  update public.companies set biometric_policy = 'required' where id = v_comp;
  perform public.service_webauthn_register(e5, 'cred-e5', k_pub, 0, array['internal'], 'phone e5');
  r := public.service_login_context('cred-e5');
  perform pg_temp.ok(r ->> 'employee_id' = e5::text, 'an ordinary employee can sign in with the phone (biometric on)', r::text);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', e5, 'viewer'));
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-e5'));
  perform pg_temp.ok(s = 'password_required', 'a viewer signs in with the password only', s);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', e5, 'hr_admin'));
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-e5'));
  perform pg_temp.ok(s = 'password_required', 'an hr_admin signs in with the password only', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_delete_employee(%L, %L)', e5, (select e.full_name from public.employees e where e.id = e5)));
  perform pg_temp.ok(s = 'is_admin', 'an account that holds a level cannot be deleted before the level is taken away', s);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', e5, 'employee'));
  r := public.service_login_context('cred-e5');
  perform pg_temp.ok(r ->> 'employee_id' = e5::text, 'after the level is taken away the phone works again', r::text);
  s := pg_temp.try_as(v_owner, format('select public.admin_delete_employee(%L, %L)', e5, 'wrong name'));
  perform pg_temp.ok(s = 'name_mismatch', 'then the normal delete checks apply again', s);

  -- ---------------------------------------------------------------- another company
  perform pg_temp.as_user(v_owner);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار المستويات', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'roles-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2;
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', e2, 'viewer'));
  perform pg_temp.ok(s = 'not_found', 'an owner cannot give a level to an employee of another company', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = e2) = 'employee', '... and he is unchanged');
  s := pg_temp.try_as(a, format('select public.admin_update_employee(%L, %L, null, true, false)', e2, 'x'));
  perform pg_temp.ok(s = 'employee_not_found', 'an hr_admin cannot edit an employee of another company', s);
  r := pg_temp.run_as(a, 'select coalesce(jsonb_agg(q.id), ''[]'') from public.admin_list_employees() q');
  perform pg_temp.ok(not r ? e2::text and jsonb_array_length(r) > 10, 'a limited level reads only his own company', jsonb_array_length(r)::text);
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
