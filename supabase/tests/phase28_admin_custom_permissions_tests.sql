-- Phase 28: custom permissions for system admins (level 'custom_admin' = the viewer set + named groups chosen by the owner).
-- Run with: psql -v admin_email=<company admin email> -f <this file>   (supabase/local/test-db.sh runs it on a fresh copy)
-- The owner chooses groups per admin with public.admin_set_admin_grants(employee, groups[]). The gate (require_company_admin, phase 26) lets a
-- custom admin reach: the viewer functions + the functions of his groups, in his own company only. Everything else stays owner-only.
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
create function pg_temp.sorted(a text[]) returns text[] language sql as
  $$ select coalesce(array_agg(distinct x order by x), '{}') from unnest(a) x $$;
create function pg_temp.perm_list(r jsonb) returns text[] language sql as
  $$ select coalesce(array_agg(x order by x), '{}') from jsonb_array_elements_text(r -> 'permissions') x $$;

do $tests$
declare
  v_owner uuid; v_comp uuid; v_comp2 uuid;
  k1 uuid; k2 uuid; k3 uuid; k4 uuid; kall uuid; hr uuid; sup uuid; vw uuid; pl uuid; pl2 uuid; x uuid;
  e2 uuid; o2 uuid; tmp uuid;
  r jsonb; s text; n int; n0 int; g0 int; a0 int; v_name text; v_exp text[]; v_bad int; v_seen int;
  k_pub text := 'pQECAyYgASFYIGZha2UtcHVibGljLWtleS14LWNvb3JkaW5hdGUtMzJiIlggZmFrZS1wdWJsaWMta2V5LXktY29vcmRpbmF0ZS0zMmI';
  v_viewer text[] := array['admin_get_approval_chains', 'admin_get_auto_punch_mode', 'admin_get_company_settings', 'admin_get_grace_settings',
    'admin_get_holiday_settings', 'admin_get_leave_policy', 'admin_get_leave_window', 'admin_get_overtime_settings',
    'admin_get_profile_visibility', 'admin_get_punch_settings', 'admin_list_attendance', 'admin_list_custom_kinds',
    'admin_list_employee_managers', 'admin_list_employees', 'admin_list_holidays', 'admin_list_leave_day_cancellations',
    'admin_list_leave_days', 'admin_list_missing_checkins', 'admin_list_overtime', 'admin_list_permission_types',
    'admin_list_requests', 'admin_list_work_locations', 'admin_punch_mode_preview'];
  v_dec text[] := array['admin_decide_leave_day', 'admin_decide_request', 'admin_dismiss_missing_checkin', 'admin_get_employee_grace',
    'admin_get_employee_kind_days', 'admin_get_leave_years', 'admin_resolve_leave_conflict', 'admin_resolve_review', 'admin_review_queue'];
  v_emp text[] := array['admin_get_employee_profile', 'admin_save_employee_profile', 'admin_update_employee', 'admin_set_employee_manager',
    'admin_set_leave_year', 'admin_set_employee_kind_days', 'admin_set_employee_grace', 'admin_set_employee_punch_windows',
    'admin_list_device_bindings', 'admin_remove_device', 'admin_get_employee_grace', 'admin_get_employee_kind_days', 'admin_get_leave_years'];
  v_wp text[] := array['admin_set_geofence', 'admin_use_location_geofence', 'admin_set_employee_location_policy'];
  v_pun text[] := array['admin_add_punch', 'admin_edit_punch'];
  v_never text[] := array['admin_list_admins', 'admin_add_admin', 'admin_remove_admin', 'admin_list_admin_roles', 'admin_set_admin_role',
    'admin_list_admin_grants', 'admin_set_admin_grants', 'admin_company_id', 'admin_delete_employee', 'admin_set_company_name',
    'admin_set_company_settings'];
begin
  select u.id into v_owner from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_owner;
  select id into k1   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 0 limit 1;
  select id into k2   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 1 limit 1;
  select id into k3   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 2 limit 1;
  select id into k4   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 3 limit 1;
  select id into kall from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 4 limit 1;
  select id into hr   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 5 limit 1;
  select id into sup  from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 6 limit 1;
  select id into vw   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 7 limit 1;
  select id into pl   from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 8 limit 1;
  select id into pl2  from public.employees e where e.is_active and e.id <> v_owner and e.company_id = v_comp order by employee_number offset 9 limit 1;
  select id into x    from public.employees e where not e.is_active and e.company_id = v_comp order by employee_number limit 1;
  perform pg_temp.ok(k1 is not null and k2 is not null and k3 is not null and k4 is not null and kall is not null and hr is not null
                     and sup is not null and vw is not null and pl is not null and pl2 is not null and x is not null,
                     'fixture: ten active employees and one inactive employee');
  select e.full_name into v_name from public.employees e where e.id = pl;
  delete from public.audit_log where action in ('admin.role_changed', 'admin.added', 'admin.removed', 'admin.grants_changed');
  -- the three phase 26 levels exist next to the custom admins
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', hr, 'hr_admin'));
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', sup, 'supervisor'));
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', vw, 'viewer'));
  -- the second company, one employee and one owner in it
  perform pg_temp.as_user(v_owner);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار الصلاحيات المخصصة', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'grants-e2@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف الشركة الثانية"}')
  returning id into e2;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'grants-o2@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"مدير الشركة الثانية"}')
  returning id into o2;
  update public.company_members set role = 'company_admin' where user_id = o2;

  -- ---------------------------------------------------------------- the catalogue (data) and what is private
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_set_admin_grants(uuid, text[])', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_list_admin_grants()', 'execute'),
                     'signed-in users can call the two new functions (the owner check is inside)');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_set_admin_grants(uuid, text[])', 'execute')
                     and not has_function_privilege('anon', 'public.admin_list_admin_grants()', 'execute'),
                     'anonymous visitors cannot call them');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.admin_may_call(uuid, uuid, text, text)', 'execute')
                     and not has_function_privilege('authenticated', 'private.admin_permissions_of(uuid, uuid, text)', 'execute')
                     and not has_function_privilege('anon', 'private.admin_may_call(uuid, uuid, text, text)', 'execute'),
                     'the two helpers are private');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'private.admin_grants', 'select')
                     and not has_table_privilege('authenticated', 'private.admin_groups', 'select')
                     and not has_table_privilege('authenticated', 'private.admin_group_rpcs', 'select')
                     and not has_table_privilege('anon', 'private.admin_grants', 'select'),
                     'the three tables are private');
  perform pg_temp.ok((select array_agg(g.group_key order by g.group_key) from private.admin_groups g) = array['decisions', 'employees', 'punches', 'workplace'],
                     'exactly four groups');
  perform pg_temp.ok(pg_temp.sorted((select array_agg(g.rpc) from private.admin_group_rpcs g where g.group_key = 'decisions')) = pg_temp.sorted(v_dec),
                     'group decisions: its functions');
  perform pg_temp.ok(pg_temp.sorted((select array_agg(g.rpc) from private.admin_group_rpcs g where g.group_key = 'employees')) = pg_temp.sorted(v_emp),
                     'group employees: its functions');
  perform pg_temp.ok(pg_temp.sorted((select array_agg(g.rpc) from private.admin_group_rpcs g where g.group_key = 'workplace')) = pg_temp.sorted(v_wp),
                     'group workplace: its functions');
  perform pg_temp.ok(pg_temp.sorted((select array_agg(g.rpc) from private.admin_group_rpcs g where g.group_key = 'punches')) = pg_temp.sorted(v_pun),
                     'group punches: its functions');
  perform pg_temp.ok(not exists (select 1 from private.admin_group_rpcs g where g.rpc = any (v_never)),
                     'no group can ever hold an owner-only function (admin management, delete employee, company settings)');
  perform pg_temp.ok(not exists (select 1 from private.admin_group_rpcs g where not exists (
                       select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = g.rpc)),
                     'every function named in the catalogue exists');
  perform pg_temp.ok(not exists (select 1 from private.admin_group_rpcs g where g.rpc <> 'admin_edit_punch' and not exists (
                       select 1 from private.admin_role_rpcs r where r.role = 'hr_admin' and r.rpc = g.rpc)),
                     'a group never holds a power the HR admin level does not have, except editing the time of a movement');
  perform pg_temp.ok(pg_temp.sorted((select array_agg(r.rpc) from private.admin_role_rpcs r where r.role = 'viewer')) = pg_temp.sorted(v_viewer),
                     'the read-only base of a custom admin is the viewer list of phase 26');

  -- ---------------------------------------------------------------- the owner chooses the groups
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k1, array['decisions']));
  perform pg_temp.ok(r ->> 'role' = 'custom_admin' and r ->> 'previous' = 'employee' and r ->> 'employee_id' = k1::text
                     and r -> 'groups' = '["decisions"]'::jsonb
                     and r ->> 'full_name' = (select e.full_name from public.employees e where e.id = k1), 'owner makes K1 a custom admin: decisions', r::text);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k2, array['employees']));
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k3, array['workplace']));
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k4, array['punches']));
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', kall, array['workplace', 'decisions', 'employees', 'decisions', 'punches']));
  perform pg_temp.ok(r -> 'groups' = '["decisions","employees","punches","workplace"]'::jsonb, 'the groups come back sorted, without duplicates', r::text);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = k1) = 'custom_admin'
                     and (select m.role from public.company_members m where m.user_id = kall) = 'custom_admin', 'the role is stored');
  perform pg_temp.ok((select count(*) from private.admin_grants) = 8
                     and (select count(*) from private.admin_grants g where g.company_id = v_comp and g.granted_by = v_owner) = 8,
                     'eight grant rows, all in his company, written by the owner');
  r := pg_temp.run_as(v_owner, 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from public.admin_list_admin_grants() q');
  perform pg_temp.ok(jsonb_array_length(r) = 8 and exists (select 1 from jsonb_array_elements(r) j where j ->> 'user_id' = k1::text and j ->> 'group_key' = 'decisions'),
                     'the owner lists the grants of his company', left(r::text, 200));
  r := pg_temp.run_as(v_owner, 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from public.admin_list_admin_roles() q');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r) j where j ->> 'id' = k1::text and j ->> 'role' = 'custom_admin'),
                     'the phase 26 list shows the new level', left(r::text, 200));
  -- the audit: one level change and one grants record per person
  perform pg_temp.ok((select count(*) from public.audit_log where company_id = v_comp and action = 'admin.role_changed' and actor_id = v_owner
                        and target_id in (k1::text, k2::text, k3::text, k4::text, kall::text)) = 5
                     and (select count(*) from public.audit_log where company_id = v_comp and action = 'admin.grants_changed' and actor_id = v_owner) = 5,
                     'five level changes and five grants records audited');
  select l.details into r from public.audit_log l where l.action = 'admin.grants_changed' and l.target_id = k1::text;
  perform pg_temp.ok(r -> 'to' = '["decisions"]'::jsonb and r -> 'from' = '[]'::jsonb
                     and r ->> 'employee_number' = (select e.employee_number from public.employees e where e.id = k1), 'the grants record says from, to and the number', r::text);
  select l.details into r from public.audit_log l where l.action = 'admin.role_changed' and l.target_id = k1::text;
  perform pg_temp.ok(r ->> 'from' = 'employee' and r ->> 'to' = 'custom_admin', 'the level record says employee to custom_admin', r::text);

  -- ---------------------------------------------------------------- refusals (and nothing is written)
  select count(*) into g0 from private.admin_grants;
  select count(*) into a0 from public.audit_log where company_id = v_comp;
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', pl, null::text[]));
  perform pg_temp.ok(s = 'no_groups', 'no groups at all is refused (use a level or "employee" instead)', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', pl, array[]::text[]));
  perform pg_temp.ok(s = 'no_groups', 'an empty list is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', pl, array['nope']));
  perform pg_temp.ok(s = 'invalid_group', 'an unknown group is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k1, array['decisions', 'nope']));
  perform pg_temp.ok(s = 'invalid_group', 'a list with one unknown group is refused as a whole', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', v_owner, array['punches']));
  perform pg_temp.ok(s = 'cannot_change_self', 'nobody changes his own level', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', gen_random_uuid(), array['punches']));
  perform pg_temp.ok(s = 'not_found', 'an unknown employee is refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', x, array['punches']));
  perform pg_temp.ok(s = 'employee_inactive', 'an inactive employee cannot get groups', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k1, array['decisions']));
  perform pg_temp.ok(s = 'no_change', 'the same groups again are refused', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', pl, 'custom_admin'));
  perform pg_temp.ok(s = 'invalid_role', 'the phase 26 function cannot make a custom admin (groups would be missing)', s);
  perform pg_temp.ok((select count(*) from private.admin_grants) = g0 and (select count(*) from public.audit_log where company_id = v_comp) = a0
                     and (select m.role from public.company_members m where m.user_id = pl) = 'employee',
                     'every refused call wrote nothing');
  -- only the owner chooses groups
  s := pg_temp.try_as(hr, format('select public.admin_set_admin_grants(%L, %L)', pl, array['punches']));
  perform pg_temp.ok(s = 'forbidden', 'an hr_admin cannot choose groups', s);
  s := pg_temp.try_as(sup, format('select public.admin_set_admin_grants(%L, %L)', pl, array['punches']));
  perform pg_temp.ok(s = 'forbidden', 'a supervisor cannot choose groups', s);
  s := pg_temp.try_as(vw, 'select count(*) from public.admin_list_admin_grants()');
  perform pg_temp.ok(s = 'forbidden', 'a viewer cannot list the grants', s);
  s := pg_temp.try_as(kall, format('select public.admin_set_admin_grants(%L, %L)', pl, array['punches']));
  perform pg_temp.ok(s = 'forbidden', 'a custom admin with every group still cannot choose groups', s);
  s := pg_temp.try_as(kall, 'select count(*) from public.admin_list_admin_grants()');
  perform pg_temp.ok(s = 'forbidden', '... nor list them', s);
  s := pg_temp.try_as(pl, format('select public.admin_set_admin_grants(%L, %L)', pl2, array['punches']));
  perform pg_temp.ok(s = 'forbidden', 'an ordinary employee cannot choose groups', s);
  perform pg_temp.ok((select count(*) from private.admin_grants) = g0, 'and none of those calls wrote anything');

  -- ---------------------------------------------------------------- the gate, call by call
  -- K1: decisions
  s := pg_temp.try_as(k1, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = '', 'K1 (decisions): the read-only base is open', s);
  s := pg_temp.try_as(k1, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = '', 'K1: the review queue', s);
  s := pg_temp.try_as(k1, format('select public.admin_decide_request(%L, %L, null, null)', gen_random_uuid(), 'approved'));
  perform pg_temp.ok(s <> 'forbidden' and s <> '', 'K1: the gate opens for a decision (the request itself is not found)', s);
  s := pg_temp.try_as(k1, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = 'forbidden', 'K1: no employee files', s);
  s := pg_temp.try_as(k1, format('select public.admin_set_geofence(%L, ''x'', 0, 0, 100)', pl));
  perform pg_temp.ok(s = 'forbidden', 'K1: no geofence', s);
  s := pg_temp.try_as(k1, format('select public.admin_add_punch(%L, ''check_in'', now() - interval ''1 hour'', ''x'')', pl));
  perform pg_temp.ok(s = 'forbidden', 'K1: no manual punch', s);
  s := pg_temp.try_as(k1, format('select public.admin_edit_punch(%L, now() - interval ''1 hour'', ''abc'')', gen_random_uuid()));
  perform pg_temp.ok(s = 'forbidden', 'K1: no punch edit', s);
  -- K2: employees
  s := pg_temp.try_as(k2, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = '', 'K2 (employees): the employee file', s);
  s := pg_temp.try_as(k2, format('select public.admin_update_employee(%L, %L, null, true, false)', pl, v_name));
  perform pg_temp.ok(s = '', 'K2: edit an employee', s);
  s := pg_temp.try_as(k2, format('select public.admin_get_employee_grace(%L)', pl));
  perform pg_temp.ok(s <> 'forbidden', 'K2: the read the employee form needs is open too', s);
  s := pg_temp.try_as(k2, format('select public.admin_set_employee_grace(%L, 5, 5)', pl));
  perform pg_temp.ok(s <> 'forbidden', 'K2: the employee form saves the grace period too', s);
  s := pg_temp.try_as(k2, 'select count(*) from public.admin_list_device_bindings()');
  perform pg_temp.ok(s <> 'forbidden', 'K2: the employee form lists his phone binding', s);
  s := pg_temp.try_as(k2, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'K2: no review queue', s);
  s := pg_temp.try_as(k2, format('select public.admin_decide_request(%L, %L, null, null)', gen_random_uuid(), 'approved'));
  perform pg_temp.ok(s = 'forbidden', 'K2: no decisions', s);
  s := pg_temp.try_as(k2, format('select public.admin_set_geofence(%L, ''x'', 0, 0, 100)', pl));
  perform pg_temp.ok(s = 'forbidden', 'K2: no geofence', s);
  s := pg_temp.try_as(k2, format('select public.admin_add_punch(%L, ''check_in'', now() - interval ''1 hour'', ''x'')', pl));
  perform pg_temp.ok(s = 'forbidden', 'K2: no manual punch', s);
  -- K3: workplace
  s := pg_temp.try_as(k3, format('select public.admin_set_geofence(%L, ''x'', 0, 0, 100)', pl));
  perform pg_temp.ok(s <> 'forbidden', 'K3 (workplace): the gate opens for the geofence', s);
  s := pg_temp.try_as(k3, format('select public.admin_use_location_geofence(%L)', pl));
  perform pg_temp.ok(s <> 'forbidden', 'K3: the gate opens for the location geofence', s);
  s := pg_temp.try_as(k3, format('select public.admin_remove_device(%L)', pl));
  perform pg_temp.ok(s = 'forbidden', 'K3: devices belong to the employee form, not to the workplace group', s);
  s := pg_temp.try_as(k3, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = 'forbidden', 'K3: no employee files', s);
  s := pg_temp.try_as(k3, format('select public.admin_decide_request(%L, %L, null, null)', gen_random_uuid(), 'approved'));
  perform pg_temp.ok(s = 'forbidden', 'K3: no decisions', s);
  -- K4: punches
  s := pg_temp.try_as(k4, format('select public.admin_add_punch(%L, ''check_in'', now() - interval ''1 hour'', ''x'')', pl));
  perform pg_temp.ok(s <> 'forbidden', 'K4 (punches): the gate opens for a manual punch', s);
  s := pg_temp.try_as(k4, format('select public.admin_edit_punch(%L, now() - interval ''1 hour'', ''abc'')', gen_random_uuid()));
  perform pg_temp.ok(s = 'not_found', 'K4: the gate opens for a punch edit (the movement itself is not found)', s);
  s := pg_temp.try_as(k4, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = 'forbidden', 'K4: no employee files', s);
  s := pg_temp.try_as(k4, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'K4: no review queue', s);
  -- KALL: every group, still not the owner-only functions
  s := pg_temp.try_as(kall, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = '', 'KALL: decisions', s);
  s := pg_temp.try_as(kall, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = '', 'KALL: employees', s);
  s := pg_temp.try_as(kall, format('select public.admin_edit_punch(%L, now() - interval ''1 hour'', ''abc'')', gen_random_uuid()));
  perform pg_temp.ok(s = 'not_found', 'KALL: punches', s);
  s := pg_temp.try_as(kall, 'select public.admin_set_company_name(''x'')');
  perform pg_temp.ok(s = 'forbidden', 'KALL: cannot rename the company', s);
  s := pg_temp.try_as(kall, 'select count(*) from public.admin_list_deduction_policies()');
  perform pg_temp.ok(s = 'forbidden', 'KALL: no payroll policies', s);
  s := pg_temp.try_as(kall, 'select public.admin_set_auto_punch_mode(true)');
  perform pg_temp.ok(s = 'forbidden', 'KALL: cannot change the automatic punch mode', s);
  s := pg_temp.try_as(kall, format('select public.admin_set_admin_role(%L, %L)', pl, 'viewer'));
  perform pg_temp.ok(s = 'forbidden', 'KALL: cannot set levels', s);
  s := pg_temp.try_as(kall, format('select public.admin_add_admin(%L)', pl));
  perform pg_temp.ok(s = 'forbidden', 'KALL: cannot make an owner', s);
  s := pg_temp.try_as(kall, format('select public.admin_delete_employee(%L, %L)', pl, v_name));
  perform pg_temp.ok(s = 'forbidden', 'KALL: cannot delete an employee', s);
  -- an ordinary employee has no door at all
  s := pg_temp.try_as(pl, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = 'forbidden', 'an ordinary employee reaches nothing', s);
  -- the three phase 26 levels did not change
  s := pg_temp.try_as(vw, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'a viewer is still read-only', s);
  s := pg_temp.try_as(sup, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = '', 'a supervisor still has the review queue', s);
  s := pg_temp.try_as(hr, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = '', 'an hr_admin still has the employee files', s);

  -- ---------------------------------------------------------------- the gate, every admin function (helper sweep)
  select count(*) into v_seen from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'admin\_%';
  perform pg_temp.ok(v_seen >= 80, 'the sweep covers every admin function of the schema', v_seen::text);
  v_exp := v_viewer || v_dec;
  select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'admin\_%'
     and private.admin_may_call(k1, v_comp, 'custom_admin', p.proname) <> (p.proname = any (v_exp));
  perform pg_temp.ok(v_bad = 0, 'sweep K1: exactly the viewer list + decisions', v_bad::text);
  v_exp := v_viewer || v_emp;
  select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'admin\_%'
     and private.admin_may_call(k2, v_comp, 'custom_admin', p.proname) <> (p.proname = any (v_exp));
  perform pg_temp.ok(v_bad = 0, 'sweep K2: exactly the viewer list + employees', v_bad::text);
  v_exp := v_viewer || v_wp;
  select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'admin\_%'
     and private.admin_may_call(k3, v_comp, 'custom_admin', p.proname) <> (p.proname = any (v_exp));
  perform pg_temp.ok(v_bad = 0, 'sweep K3: exactly the viewer list + workplace', v_bad::text);
  v_exp := v_viewer || v_pun;
  select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'admin\_%'
     and private.admin_may_call(k4, v_comp, 'custom_admin', p.proname) <> (p.proname = any (v_exp));
  perform pg_temp.ok(v_bad = 0, 'sweep K4: exactly the viewer list + punches', v_bad::text);
  v_exp := v_viewer || v_dec || v_emp || v_wp || v_pun;
  select count(*) into v_bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'admin\_%'
     and private.admin_may_call(kall, v_comp, 'custom_admin', p.proname) <> (p.proname = any (v_exp));
  perform pg_temp.ok(v_bad = 0, 'sweep KALL: exactly the viewer list + all four groups', v_bad::text);
  perform pg_temp.ok(not exists (select 1 from unnest(v_never) f where private.admin_may_call(kall, v_comp, 'custom_admin', f)),
                     'sweep: the owner-only list is closed even to the custom admin with every group');
  perform pg_temp.ok(not private.admin_may_call(k1, v_comp2, 'custom_admin', 'admin_review_queue'),
                     'the same person in another company has no grants there');
  perform pg_temp.ok(not private.admin_may_call(pl, v_comp, 'custom_admin', 'admin_review_queue'),
                     'a person without grants has nothing beyond the base');
  perform pg_temp.ok(private.admin_may_call(pl, v_comp, 'custom_admin', 'admin_list_requests'),
                     '... and the base is always there');
  perform pg_temp.ok(not private.admin_may_call(k1, v_comp, 'viewer', 'admin_review_queue')
                     and private.admin_may_call(k1, v_comp, 'hr_admin', 'admin_set_geofence')
                     and not private.admin_may_call(k1, v_comp, 'employee', 'admin_list_requests')
                     and not private.admin_may_call(k1, v_comp, 'bogus', 'admin_list_requests'),
                     'the fixed levels still read their own list; any other role gets nothing');

  -- ---------------------------------------------------------------- the context the panel reads
  r := pg_temp.run_as(k1, 'select public.my_admin_context()');
  perform pg_temp.ok(r ->> 'admin_role' = 'custom_admin' and (r ->> 'is_panel_user')::boolean and not (r ->> 'is_company_admin')::boolean
                     and r ->> 'company_role' = 'custom_admin' and jsonb_typeof(r -> 'permissions') = 'array'
                     and pg_temp.perm_list(r) = pg_temp.sorted(v_viewer || v_dec),
                     'K1 context: custom_admin, panel user, not owner, permissions = base + decisions', left(r::text, 200));
  r := pg_temp.run_as(kall, 'select public.my_admin_context()');
  perform pg_temp.ok(pg_temp.perm_list(r) = pg_temp.sorted(v_viewer || v_dec || v_emp || v_wp || v_pun),
                     'KALL context: base + all four groups');
  r := pg_temp.run_as(pl, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_panel_user')::boolean and r -> 'admin_role' = 'null'::jsonb and r -> 'permissions' = 'null'::jsonb,
                     'an ordinary employee: no level, no list');
  r := pg_temp.run_as(v_owner, 'select public.my_admin_context()');
  perform pg_temp.ok(r ->> 'admin_role' = 'company_admin' and r -> 'permissions' = 'null'::jsonb, 'the owner: unchanged (null list = everything)');
  r := pg_temp.run_as(hr, 'select public.my_admin_context()');
  perform pg_temp.ok(r ->> 'admin_role' = 'hr_admin' and r -> 'permissions' ? 'admin_get_employee_profile', 'an hr_admin: unchanged');

  -- ---------------------------------------------------------------- replace, remove, change level
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k1, array['punches', 'employees']));
  perform pg_temp.ok(r ->> 'previous' = 'custom_admin' and r -> 'groups' = '["employees","punches"]'::jsonb, 'new groups replace the old ones', r::text);
  perform pg_temp.ok(not exists (select 1 from private.admin_grants g where g.user_id = k1 and g.group_key = 'decisions')
                     and (select count(*) from private.admin_grants g where g.user_id = k1) = 2, 'the old group is gone from the table');
  s := pg_temp.try_as(k1, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'and its door is shut at once', s);
  select l.details into r from public.audit_log l where l.action = 'admin.grants_changed' and l.target_id = k1::text order by l.created_at desc, l.id desc limit 1;
  perform pg_temp.ok(r -> 'from' = '["decisions"]'::jsonb and r -> 'to' = '["employees","punches"]'::jsonb, 'the second grants record keeps the previous set', r::text);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k1, array['decisions']));
  -- another level: the groups are deleted
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', k1, 'viewer'));
  perform pg_temp.ok(r ->> 'previous' = 'custom_admin' and r ->> 'role' = 'viewer', 'a custom admin can be moved to a fixed level', r::text);
  perform pg_temp.ok(not exists (select 1 from private.admin_grants g where g.user_id = k1), 'his groups are deleted with the move');
  s := pg_temp.try_as(k1, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'he is a plain viewer now', s);
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k1, array['decisions']));
  perform pg_temp.ok(r ->> 'previous' = 'viewer' and r ->> 'role' = 'custom_admin', 'and from a fixed level to custom again', r::text);
  -- removing the level: the groups are deleted, he is an employee again
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', k4, 'employee'));
  perform pg_temp.ok(not exists (select 1 from private.admin_grants g where g.user_id = k4)
                     and (select m.role from public.company_members m where m.user_id = k4) = 'employee', 'removing the level deletes the groups');
  r := pg_temp.run_as(k4, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_panel_user')::boolean and r -> 'admin_role' = 'null'::jsonb, 'and he is no panel user');
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', k4, array['punches']));
  -- an owner can become a custom admin; the phase 16 record is kept true
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', pl2, 'company_admin'));
  perform pg_temp.ok(private.working_admin_count(v_comp, null) = 2, 'a second owner exists');
  r := pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', pl2, array['punches']));
  perform pg_temp.ok(r ->> 'previous' = 'company_admin' and r ->> 'role' = 'custom_admin', 'the owner moves the second owner to custom', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'admin.removed' and target_id = pl2::text and actor_id = v_owner) = 1
                     and private.working_admin_count(v_comp, null) = 1, 'an owner demotion also writes the phase 16 record admin.removed');
  r := pg_temp.run_as(pl2, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_company_admin')::boolean and r ->> 'admin_role' = 'custom_admin', 'he is no owner any more', r::text);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', pl2, 'employee'));

  -- ---------------------------------------------------------------- stale rows are inert
  insert into private.admin_grants (company_id, user_id, group_key, granted_by) values (v_comp, vw, 'decisions', v_owner);
  s := pg_temp.try_as(vw, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'a grant row of someone who is not a custom admin opens nothing', s);
  r := pg_temp.run_as(vw, 'select public.my_admin_context()');
  perform pg_temp.ok(not r -> 'permissions' ? 'admin_review_queue', '... and is not in his permission list');
  delete from private.admin_grants where user_id = vw;
  insert into private.admin_grants (company_id, user_id, group_key, granted_by) values (v_comp2, k3, 'decisions', v_owner);
  s := pg_temp.try_as(k3, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', 'a grant row of another company opens nothing', s);
  r := pg_temp.run_as(k3, 'select public.my_admin_context()');
  perform pg_temp.ok(not r -> 'permissions' ? 'admin_review_queue', '... and is not in his permission list');
  delete from private.admin_grants where user_id = k3 and company_id = v_comp2;
  -- an account that disappears takes its groups with it
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'grants-tmp@example.com', jsonb_build_object('company_id', v_comp), '{"full_name":"حساب مؤقت"}') returning id into tmp;
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', tmp, array['punches']));
  perform pg_temp.ok((select count(*) from private.admin_grants g where g.user_id = tmp) = 1, 'fixture: a temporary custom admin');
  delete from auth.users where id = tmp;
  perform pg_temp.ok(not exists (select 1 from private.admin_grants g where g.user_id = tmp), 'deleting the account deletes his groups');

  -- ---------------------------------------------------------------- what a custom admin still cannot do
  s := pg_temp.try_as(k2, format('select public.admin_update_employee(%L, %L, null, true, false)', hr, 'x'));
  perform pg_temp.ok(s = 'forbidden', 'K2 (employees) cannot edit an hr_admin', s);
  s := pg_temp.try_as(k2, format('select public.admin_update_employee(%L, %L, null, true, false)', v_owner, 'x'));
  perform pg_temp.ok(s = 'forbidden', 'K2 cannot edit the owner', s);
  s := pg_temp.try_as(k2, format('select public.admin_update_employee(%L, %L, null, true, false)', k1, 'x'));
  perform pg_temp.ok(s = 'forbidden', 'K2 cannot edit another custom admin', s);
  s := pg_temp.try_as(k2, format('select public.admin_update_employee(%L, %L, null, true, false)', pl, v_name));
  perform pg_temp.ok(s = '', 'K2 can edit an ordinary employee', s);
  s := pg_temp.try_as(v_owner, format('select public.admin_delete_employee(%L, %L)', k3, (select e.full_name from public.employees e where e.id = k3)));
  perform pg_temp.ok(s = 'is_admin', 'an account with groups cannot be deleted before the level is taken away', s);
  s := pg_temp.try_as(k1, 'select count(*) from public.admin_review_queue()', '{"must_change_password": true}'::jsonb);
  perform pg_temp.ok(s = 'must_change_password', 'a temporary password must be replaced first, like every admin', s);
  update public.companies set biometric_policy = 'required' where id = v_comp;
  perform public.service_webauthn_register(pl, 'cred-pl', k_pub, 0, array['internal'], 'phone pl');
  r := public.service_login_context('cred-pl');
  perform pg_temp.ok(r ->> 'employee_id' = pl::text, 'fixture: an ordinary employee signs in with the phone', r::text);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', pl, array['punches']));
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-pl'));
  perform pg_temp.ok(s = 'password_required', 'a custom admin signs in with the password only', s);
  perform pg_temp.run_as(v_owner, format('select public.admin_set_admin_role(%L, %L)', pl, 'employee'));
  r := public.service_login_context('cred-pl');
  perform pg_temp.ok(r ->> 'employee_id' = pl::text, 'after the level is taken away the phone works again', r::text);
  -- an inactive employee or an inactive company loses the door
  update public.employees set is_active = false where id = k3;
  s := pg_temp.try_as(k3, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = 'forbidden', 'a deactivated custom admin reaches nothing', s);
  update public.employees set is_active = true where id = k3;
  s := pg_temp.try_as(k3, 'select count(*) from public.admin_list_requests()');
  perform pg_temp.ok(s = '', '... and gets it back when reactivated', s);

  -- ---------------------------------------------------------------- another company
  s := pg_temp.try_as(v_owner, format('select public.admin_set_admin_grants(%L, %L)', e2, array['punches']));
  perform pg_temp.ok(s = 'not_found', 'an owner cannot give groups to an employee of another company', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = e2) = 'employee', '... and he is unchanged');
  s := pg_temp.try_as(o2, format('select public.admin_set_admin_grants(%L, %L)', k2, array['punches']));
  perform pg_temp.ok(s = 'not_found', 'the owner of the other company cannot touch ours either', s);
  perform pg_temp.ok((select array_agg(g.group_key) from private.admin_grants g where g.user_id = k2) = array['employees'], '... and K2 is unchanged');
  r := pg_temp.run_as(o2, format('select public.admin_set_admin_grants(%L, %L)', e2, array['decisions']));
  perform pg_temp.ok(r ->> 'role' = 'custom_admin' and r ->> 'previous' = 'employee', 'the other owner chooses groups inside his own company', r::text);
  perform pg_temp.ok((select g.company_id from private.admin_grants g where g.user_id = e2) = v_comp2, '... stored with his company');
  r := pg_temp.run_as(o2, 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from public.admin_list_admin_grants() q');
  perform pg_temp.ok(jsonb_array_length(r) = 1 and r -> 0 ->> 'user_id' = e2::text, 'he lists only his own company''s grants', r::text);
  r := pg_temp.run_as(v_owner, 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]'') from public.admin_list_admin_grants() q');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r) j where j ->> 'user_id' = e2::text), 'and our owner does not see his');
  s := pg_temp.try_as(e2, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = '', 'the custom admin of the other company has his own group', s);
  s := pg_temp.try_as(e2, format('select public.admin_get_employee_profile(%L)', pl));
  perform pg_temp.ok(s = 'forbidden', '... and nothing of the groups K2 has in our company', s);
  s := pg_temp.try_as(k2, format('select public.admin_get_employee_profile(%L)', e2));
  perform pg_temp.ok(s <> '' and s <> 'forbidden', 'K2 (employees) cannot read an employee of the other company', s);
  r := pg_temp.run_as(k2, 'select coalesce(jsonb_agg(q.id), ''[]'') from public.admin_list_employees() q');
  perform pg_temp.ok(not r ? e2::text and jsonb_array_length(r) > 10, 'a custom admin lists only his own company', jsonb_array_length(r)::text);
  update public.companies set is_active = false where id = v_comp2;
  r := pg_temp.run_as(e2, 'select public.my_admin_context()');
  perform pg_temp.ok(not (r ->> 'is_panel_user')::boolean and r -> 'admin_role' = 'null'::jsonb, 'a deactivated company shuts the door of its custom admins');
  s := pg_temp.try_as(e2, 'select count(*) from public.admin_review_queue()');
  perform pg_temp.ok(s = 'forbidden', '... for every call', s);
  update public.companies set is_active = true where id = v_comp2;
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
