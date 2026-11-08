-- Phase 21: deleting a work place and deleting an employee (soft delete, history kept).
--   public.admin_delete_work_location(p_location_id, p_move_to), public.admin_delete_employee(p_employee_id, p_confirm_name),
--   deleted_at on work_locations and employees, the two list functions that hide deleted rows, the trigger that keeps people
--   off a deleted place.  The last part uses dblink (a second and third session) to prove the row locks.
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
-- the admin adds a work place
create function pg_temp.add_loc(adm uuid, nm text) returns uuid language plpgsql as $$
declare r uuid;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_add_work_location(nm);
  reset role;
  return r;
end $$;
-- delete a place as `adm`: the result, or the error text
create function pg_temp.del_loc(adm uuid, loc uuid, tgt uuid default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_delete_work_location(loc, tgt);
  reset role;
  return r;
end $$;
create function pg_temp.del_loc_err(adm uuid, loc uuid, tgt uuid default null) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.admin_delete_work_location(loc, tgt);
    r := '';
  exception when others then r := sqlerrm;
  end;
  reset role;
  return r;
end $$;
-- delete an employee as `adm`
create function pg_temp.del_emp(adm uuid, emp uuid, nm text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_delete_employee(emp, nm);
  reset role;
  return r;
end $$;
create function pg_temp.del_emp_err(adm uuid, emp uuid, nm text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.admin_delete_employee(emp, nm);
    r := '';
  exception when others then r := sqlerrm;
  end;
  reset role;
  return r;
end $$;
-- the admin saves an employee profile (only the place and the active flag matter here); the error text or ''
create function pg_temp.save_prof_err(adm uuid, emp uuid, loc uuid, active boolean) returns text language plpgsql as $$
declare r text; e record;
begin
  select * into e from public.employees where id = emp;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.admin_save_employee_profile(emp, e.employee_number, e.full_name, 'قسم', 'وظيفة', 'male', date '1990-01-01', date '2020-01-01',
      loc, active, true, 1000, '[]'::jsonb,
      (select jsonb_agg(jsonb_build_object('weekday', g, 'is_workday', false)) from generate_series(0, 6) g), '{}'::jsonb);
    r := '';
  exception when others then r := sqlerrm;
  end;
  reset role;
  return r;
end $$;
-- a leave request written directly (as the table owner), with one hr approval row
create function pg_temp.mk_leave(p_emp uuid, p_comp uuid, p_tz text, p_from date, p_to date, p_status text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.requests (employee_id, company_id, request_type, leave_type, status, start_at, end_at, days, decided_at)
  values (p_emp, p_comp, 'leave', 'annual', p_status::public.request_status,
          greatest(p_from, (now() at time zone p_tz)::date)::timestamp at time zone p_tz,
          (p_to + 1)::timestamp at time zone p_tz, private.leave_days(p_emp, p_from, p_to), case when p_status <> 'pending' then now() end)
  returning id into v;
  update public.requests set start_at = p_from::timestamp at time zone p_tz where id = v;
  insert into public.request_approvals (company_id, request_id, step_order, approver_kind, status)
  values (p_comp, v, 1, 'hr', case p_status when 'approved' then 'approved' when 'rejected' then 'rejected' else 'pending' end);
  return v;
end $$;
-- a finished day (check-in, check-out, closed session)
create function pg_temp.mk_day(p_emp uuid, p_tz text, p_day date, p_in time, p_out time) returns void language plpgsql as $$
declare i uuid; o uuid;
begin
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (p_emp, 'check_in', (p_day + p_in) at time zone p_tz, true, 'password', 'not_requested', false, 'none', '{}'::jsonb) returning id into i;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (p_emp, 'check_out', (p_day + p_out) at time zone p_tz, true, 'password', 'not_requested', false, 'none', '{}'::jsonb) returning id into o;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, check_out_event_id, status) values (p_emp, p_day, i, o, 'closed');
end $$;
-- a check-in that is still open (the employee has not left)
create function pg_temp.mk_open(p_emp uuid, p_tz text, p_day date, p_in time) returns uuid language plpgsql as $$
declare i uuid;
begin
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (p_emp, 'check_in', (p_day + p_in) at time zone p_tz, true, 'password', 'not_requested', false, 'none', '{}'::jsonb) returning id into i;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (p_emp, p_day, i, 'open');
  return i;
end $$;
-- a flagged "missed check-out" check-in with its waiting session (an item of the review queue)
create function pg_temp.mk_flagged(p_emp uuid, p_tz text, p_day date, p_in time) returns uuid language plpgsql as $$
declare i uuid;
begin
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (p_emp, 'check_in', (p_day + p_in) at time zone p_tz, true, 'password', 'not_requested', true, 'none', jsonb_build_object('missed_checkout', true)) returning id into i;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (p_emp, p_day, i, 'missed_checkout');
  return i;
end $$;
-- ids the later blocks (and the other sessions of the race part) need; committed between blocks
create temp table t_ids (k text primary key, id uuid);
grant all on t_ids to public;

-- =====================================================================================================================
-- PART 1: the schema, the work places
-- =====================================================================================================================
do $tests$
declare
  v_admin uuid; v_comp uuid; v_comp2 uuid; v_tz text;
  em uuid[]; p1 uuid; p1b uuid; p2 uuid; p3 uuid; p4 uuid; px uuid; o_loc uuid; e_other uuid;
  r jsonb; s text; n int; l record; a_row record; v_name text;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select array_agg(x.id order by x.employee_number) into em
  from (select e.id, e.employee_number from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by e.employee_number limit 20) x;
  update public.employees set full_name = 'سالم محمد علي' where id = em[7];
  update public.employees set full_name = 'ليلى أحمد' where id = em[8];
  update public.employees set full_name = 'خالد يوسف' where id = em[9];
  update public.employees set full_name = 'منى عبدالله' where id = em[10];
  update public.employees set full_name = 'أمل حسن' where id = em[11];   -- the first letter is the one-piece alef with hamza (U+0623)
  update public.employees set full_name = 'هدى سعيد' where id = em[12];

  -- ---------------------------------------------------------------- the schema
  perform pg_temp.ok((select data_type = 'timestamp with time zone' and is_nullable = 'YES' from information_schema.columns
                      where table_schema = 'public' and table_name = 'work_locations' and column_name = 'deleted_at'), 'work_locations.deleted_at: nullable timestamptz');
  perform pg_temp.ok((select data_type = 'timestamp with time zone' and is_nullable = 'YES' from information_schema.columns
                      where table_schema = 'public' and table_name = 'employees' and column_name = 'deleted_at'), 'employees.deleted_at: nullable timestamptz');
  perform pg_temp.ok((select indexdef like '%UNIQUE%' and indexdef like '%lower(btrim(name))%' and indexdef like '%deleted_at IS NULL%'
                      from pg_indexes where schemaname = 'public' and tablename = 'work_locations' and indexname = 'work_locations_name_uidx'),
                     'the unique name index only covers places that are not deleted', (select indexdef from pg_indexes where indexname = 'work_locations_name_uidx'));
  perform pg_temp.ok(pg_get_function_result('public.admin_list_work_locations'::regproc) =
      'TABLE(id uuid, name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric, employees_count bigint, active_count bigint)',
      'admin_list_work_locations: the old columns, then active_count appended', pg_get_function_result('public.admin_list_work_locations'::regproc));
  perform pg_temp.ok(pg_get_function_result('public.admin_list_employees'::regproc) =
      'TABLE(id uuid, email text, full_name text, employee_number text, department text, is_active boolean, geofence_required boolean, created_at timestamp with time zone, geofence_id uuid, geofence_name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric, job_title text, gender text, birth_date date, hire_date date, work_location_id uuid, work_location_name text, geofence_inherited boolean, location_policy text, outside_action text, has_device boolean)',
      'admin_list_employees: exactly the old columns', pg_get_function_result('public.admin_list_employees'::regproc));
  s := pg_temp.err(format('update public.employees set deleted_at = now() where id = %L', em[16]));
  perform pg_temp.ok(s like '%employees_deleted_inactive_chk%', 'a deleted employee cannot stay active (check constraint)', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = em[16]), 'and the refused update changed nothing');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_delete_work_location(uuid, uuid)', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_delete_employee(uuid, text)', 'execute')
                     and not has_function_privilege('anon', 'public.admin_delete_work_location(uuid, uuid)', 'execute')
                     and not has_function_privilege('anon', 'public.admin_delete_employee(uuid, text)', 'execute'),
                     'the two delete functions: authenticated only, not anon');
  perform pg_temp.ok((select count(*) = 1 from pg_trigger t where t.tgrelid = 'public.employees'::regclass and not t.tgisinternal
                      and t.tgname = 'employees_guard_deleted_location'), 'the guard trigger exists once');
  perform pg_temp.ok((select pg_get_triggerdef(t.oid) like '%BEFORE INSERT OR UPDATE OF work_location_id, is_active ON%' from pg_trigger t
                      where t.tgrelid = 'public.employees'::regclass and t.tgname = 'employees_guard_deleted_location'),
                     'it fires before an insert, and before an update of the place or of is_active', (select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgname = 'employees_guard_deleted_location'));

  -- ---------------------------------------------------------------- places and people
  p1 := pg_temp.add_loc(v_admin, 'مصنع');
  p2 := pg_temp.add_loc(v_admin, 'مكتب');
  p3 := pg_temp.add_loc(v_admin, 'مخزن');
  p4 := pg_temp.add_loc(v_admin, 'فرع');
  update public.employees set work_location_id = p1 where id in (em[1], em[2], em[3]);
  update public.employees set is_active = false where id = em[3];
  update public.employees set work_location_id = p2 where id = em[4];
  update public.employees set work_location_id = p3 where id in (em[5], em[6]);
  update public.employees set is_active = false where id in (em[5], em[6]);

  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into l from public.admin_list_work_locations() x where x.id = p1;
  reset role;
  perform pg_temp.ok(l.employees_count = 3 and l.active_count = 2, 'the list: 3 employees at the place, 2 of them active', row(l.employees_count, l.active_count)::text);
  set local role authenticated;
  select * into l from public.admin_list_work_locations() x where x.id = p3;
  reset role;
  perform pg_temp.ok(l.employees_count = 2 and l.active_count = 0, 'a place with only inactive employees: 2 and 0', row(l.employees_count, l.active_count)::text);
  set local role authenticated;
  select * into l from public.admin_list_work_locations() x where x.id = p4;
  reset role;
  perform pg_temp.ok(l.employees_count = 0 and l.active_count = 0, 'an empty place: 0 and 0');

  -- another company, with its own place and employee
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار الحذف', 'Africa/Tripoli');
  reset role;
  insert into public.work_locations (company_id, name) values (v_comp2, 'مكان شركة أخرى') returning id into o_loc;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'delete-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e_other;

  -- ---------------------------------------------------------------- admin_delete_work_location: who, and what it refuses
  perform pg_temp.as_user(em[1]);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_delete_work_location(%L, null)', p4));
  reset role;
  perform pg_temp.ok(s <> '' and s <> 'has_employees' and s <> 'not_found', 'an employee cannot delete a place', s);
  perform pg_temp.ok(exists (select 1 from public.work_locations where id = p4 and deleted_at is null), 'and the place is still there');

  s := pg_temp.del_loc_err(v_admin, gen_random_uuid());
  perform pg_temp.ok(s = 'not_found', 'an unknown place: not_found', s);
  s := pg_temp.del_loc_err(v_admin, o_loc);
  perform pg_temp.ok(s = 'not_found', 'a place of another company: not_found', s);
  perform pg_temp.ok(exists (select 1 from public.work_locations where id = o_loc and deleted_at is null), 'and it is untouched');
  s := pg_temp.del_loc_err(v_admin, null);
  perform pg_temp.ok(s = 'not_found', 'no place at all: not_found', s);

  s := pg_temp.del_loc_err(v_admin, p1);
  perform pg_temp.ok(s = 'has_employees', 'active employees and no target: has_employees', s);
  perform pg_temp.ok(exists (select 1 from public.work_locations where id = p1 and deleted_at is null)
                     and (select count(*) = 3 from public.employees where work_location_id = p1), 'a refusal changes nothing (place live, nobody moved)');
  s := pg_temp.del_loc_err(v_admin, p1, p1);
  perform pg_temp.ok(s = 'invalid_target', 'the place itself as target: invalid_target', s);
  s := pg_temp.del_loc_err(v_admin, p1, o_loc);
  perform pg_temp.ok(s = 'invalid_target', 'a place of another company as target: invalid_target', s);
  s := pg_temp.del_loc_err(v_admin, p1, gen_random_uuid());
  perform pg_temp.ok(s = 'invalid_target', 'an unknown target: invalid_target', s);
  s := pg_temp.del_loc_err(v_admin, p4, p4);
  perform pg_temp.ok(s = 'invalid_target', 'the same place as target is refused even when the place is empty', s);
  perform pg_temp.ok(exists (select 1 from public.work_locations where id = p4 and deleted_at is null), 'an empty place with a bad target is not deleted');

  -- ---------------------------------------------------------------- an empty place
  r := pg_temp.del_loc(v_admin, p4);
  perform pg_temp.ok(r = '{"deleted": true, "moved": 0}'::jsonb, 'an empty place is deleted without a target: {deleted, moved 0}', r::text);
  perform pg_temp.ok((select deleted_at is not null from public.work_locations where id = p4), 'the row stays, with deleted_at set');
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'work_location.delete' and a.target_type = 'work_location' and a.target_id = p4::text
                             and a.company_id = v_comp and a.actor_id = v_admin and a.details ->> 'name' = 'فرع' and (a.details ->> 'moved')::int = 0),
                     'one audit row: work_location.delete with the name and the number moved');
  set local role authenticated;
  select count(*) into n from public.admin_list_work_locations() x where x.id = p4;
  reset role;
  perform pg_temp.ok(n = 0, 'the list no longer shows it');
  s := pg_temp.del_loc_err(v_admin, p4);
  perform pg_temp.ok(s = 'not_found', 'deleting it again: not_found', s);
  s := pg_temp.del_loc_err(v_admin, p2, p4);
  perform pg_temp.ok(s = 'invalid_target', 'a deleted place cannot be the target', s);
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'work_location.delete' and a.target_id = p4::text), 'and the refused calls wrote no audit row');

  -- ---------------------------------------------------------------- a place whose only employees are inactive (Review Focus 1)
  r := pg_temp.del_loc(v_admin, p3);
  perform pg_temp.ok(r = '{"deleted": true, "moved": 0}'::jsonb, 'only inactive employees: deleted without a target, none moved', r::text);
  perform pg_temp.ok((select count(*) = 2 and bool_and(not is_active) from public.employees where work_location_id = p3), 'those employees keep pointing at it (history)');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into a_row from public.admin_list_employees() x where x.id = em[5];
  reset role;
  perform pg_temp.ok(a_row.id is not null and a_row.work_location_id = p3 and a_row.work_location_name = 'مخزن', 'the employee list still names the old place of an inactive employee', row(a_row.work_location_name)::text);

  -- ---------------------------------------------------------------- a place with active employees: they move, the geofence follows
  set local role authenticated;
  perform public.admin_set_location_geofence(p2, 32.9, 13.2, 150);
  reset role;
  perform pg_temp.ok((select count(*) = 0 from public.employee_geofences where employee_id in (em[1], em[2]) and is_active), 'setup: the employees of the old place have no geofence');
  r := pg_temp.del_loc(v_admin, p1, p2);
  perform pg_temp.ok(r = '{"deleted": true, "moved": 2}'::jsonb, 'with a target: the two active employees move, the inactive one does not count', r::text);
  perform pg_temp.ok((select count(*) = 2 and bool_and(is_active) from public.employees where work_location_id = p2 and id in (em[1], em[2])), 'both active employees now work at the target');
  perform pg_temp.ok((select work_location_id = p1 and not is_active from public.employees where id = em[3]), 'the inactive one keeps the deleted place (history)');
  perform pg_temp.ok((select count(*) = 2 from public.employee_geofences g where g.employee_id in (em[1], em[2]) and g.is_active and g.source_location_id = p2),
                     'they inherit the target''s geofence (same copy as when the profile is saved)');
  perform pg_temp.ok((select deleted_at is not null from public.work_locations where id = p1), 'the old place is deleted');
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'work_location.delete' and a.target_id = p1::text
                             and (a.details ->> 'moved')::int = 2 and (a.details ->> 'moved_to')::uuid = p2 and a.details ->> 'name' = 'مصنع'),
                     'the audit row says where they went and how many');
  set local role authenticated;
  select * into l from public.admin_list_work_locations() x where x.id = p2;
  reset role;
  perform pg_temp.ok(l.employees_count = 3 and l.active_count = 3, 'the target now counts them: 3 and 3', row(l.employees_count, l.active_count)::text);

  -- ---------------------------------------------------------------- a name can be added again (Review Focus 2)
  p1b := pg_temp.add_loc(v_admin, 'مصنع');
  perform pg_temp.ok(p1b is not null and p1b <> p1, 'the name of a deleted place can be added again: a new place', p1b::text);
  perform pg_temp.ok((select count(*) = 1 from public.work_locations where company_id = v_comp and lower(btrim(name)) = 'مصنع' and deleted_at is null), 'exactly one live place has that name');
  px := pg_temp.add_loc(v_admin, '  مصنع  ');
  perform pg_temp.ok(px = p1b, 'adding it again (spaces around) returns the live one, not the deleted one', px::text);
  perform pg_temp.ok((select count(*) = 2 from public.work_locations where company_id = v_comp and lower(btrim(name)) = 'مصنع'), 'the deleted one and the live one both exist as rows');
  s := pg_temp.err(format('insert into public.work_locations (company_id, name) values (%L, %L)', v_comp, ' مصنع'));
  perform pg_temp.ok(s like '%work_locations_name_uidx%', 'two live places with one name are still impossible (index)', s);
  -- a deleted place can no longer be found by adding its name... but a live place's name does not come back after delete + add again
  r := pg_temp.del_loc(v_admin, p1b);
  perform pg_temp.ok(r ->> 'moved' = '0', 'the new place deletes too (nobody is there)');
  px := pg_temp.add_loc(v_admin, 'مصنع');
  perform pg_temp.ok(px <> p1b and px <> p1, 'and the name can be taken a third time', px::text);

  -- ---------------------------------------------------------------- the trigger: nobody is put on a deleted place
  s := pg_temp.err(format('update public.employees set work_location_id = %L where id = %L', p1, em[4]));
  perform pg_temp.ok(s = 'invalid_work_location', 'a direct move to a deleted place is refused', s);
  perform pg_temp.ok((select work_location_id = p2 from public.employees where id = em[4]), 'and the employee stayed where he was');
  s := pg_temp.save_prof_err(v_admin, em[4], p1, true);
  perform pg_temp.ok(s = 'invalid_work_location', 'saving a profile with a deleted place is refused', s);
  s := pg_temp.err(format('update public.employees set is_active = true where id = %L', em[3]));
  perform pg_temp.ok(s = 'invalid_work_location', 'reactivating an employee whose place was deleted is refused (he must get a live place first)', s);
  perform pg_temp.ok((select not is_active and work_location_id = p1 from public.employees where id = em[3]), 'and he stays inactive at the old place');
  s := pg_temp.save_prof_err(v_admin, em[3], p1, false);
  perform pg_temp.ok(s = '', 'an inactive employee can still be saved with his old (deleted) place, unchanged', s);
  s := pg_temp.save_prof_err(v_admin, em[3], p2, true);
  perform pg_temp.ok(s = '', 'give him a live place and he can be active again', s);
  perform pg_temp.ok((select is_active and work_location_id = p2 from public.employees where id = em[3]), 'now active at the live place');
  s := pg_temp.err(format('update public.employees set full_name = full_name where id = %L', em[3]));
  perform pg_temp.ok(s = '', 'an update that touches neither the place nor the active flag is not blocked');

  perform pg_temp.ok(true, 'END part 1');
end
$tests$;

-- =====================================================================================================================
-- PART 2: deleting an employee: every refusal, in order
-- =====================================================================================================================
do $tests$
declare
  v_admin uuid; v_comp uuid; v_comp2 uuid; v_tz text; v_today date;
  em uuid[]; e_other uuid; p2 uuid;
  v uuid; v_name text; rq uuid; ev uuid; r jsonb; s text; n int; st uuid;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  v_today := (now() at time zone v_tz)::date;
  select array_agg(x.id order by x.employee_number) into em
  from (select e.id, e.employee_number from public.employees e where e.id <> v_admin and e.company_id = v_comp order by e.employee_number limit 20) x;
  select id into e_other from auth.users where email = 'delete-iso@example.com';
  select id into p2 from public.work_locations where company_id = v_comp and name = 'مكتب' and deleted_at is null;
  v := em[7];
  v_name := (select full_name from public.employees where id = v);

  -- ---------------------------------------------------------------- who may call it, and the first refusals
  perform pg_temp.as_user(em[1]);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_delete_employee(%L, %L)', v, v_name));
  reset role;
  perform pg_temp.ok(s <> '' and s <> 'not_found' and s <> 'name_mismatch', 'an employee cannot delete an employee', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = v), 'and nothing happened');
  s := pg_temp.del_emp_err(v_admin, gen_random_uuid(), 'x');
  perform pg_temp.ok(s = 'not_found', 'an unknown employee: not_found', s);
  s := pg_temp.del_emp_err(v_admin, null, 'x');
  perform pg_temp.ok(s = 'not_found', 'no employee: not_found', s);
  s := pg_temp.del_emp_err(v_admin, e_other, 'موظف شركة أخرى');
  perform pg_temp.ok(s = 'not_found', 'an employee of another company: not_found (even with his right name)', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = e_other), 'and he is untouched');

  s := pg_temp.del_emp_err(v_admin, v_admin, (select full_name from public.employees where id = v_admin));
  perform pg_temp.ok(s = 'self_delete', 'nobody deletes himself: self_delete', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = v_admin), 'the caller is untouched');

  -- an admin
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_add_admin(em[8]);
  reset role;
  s := pg_temp.del_emp_err(v_admin, em[8], (select full_name from public.employees where id = em[8]));
  perform pg_temp.ok(s = 'is_admin', 'an admin cannot be deleted (remove the admin role first): is_admin', s);
  s := pg_temp.del_emp_err(v_admin, em[8], 'اسم خاطئ');
  perform pg_temp.ok(s = 'is_admin', 'is_admin comes before the name check', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = em[8])
                     and (select role = 'company_admin' from public.company_members where user_id = em[8]), 'and he is untouched, still an admin');

  -- the typed name
  s := pg_temp.del_emp_err(v_admin, v, 'اسم خاطئ');
  perform pg_temp.ok(s = 'name_mismatch', 'a wrong name: name_mismatch', s);
  s := pg_temp.del_emp_err(v_admin, v, '');
  perform pg_temp.ok(s = 'name_mismatch', 'an empty name: name_mismatch', s);
  s := pg_temp.del_emp_err(v_admin, v, null);
  perform pg_temp.ok(s = 'name_mismatch', 'no name at all: name_mismatch', s);
  s := pg_temp.del_emp_err(v_admin, v, '   ');
  perform pg_temp.ok(s = 'name_mismatch', 'only spaces: name_mismatch', s);
  s := pg_temp.del_emp_err(v_admin, v, 'سالم محمد');
  perform pg_temp.ok(s = 'name_mismatch', 'the beginning of the name is not enough', s);
  s := pg_temp.del_emp_err(v_admin, v, v_name || 'x');
  perform pg_temp.ok(s = 'name_mismatch', 'the name plus a letter is not enough', s);
  s := pg_temp.del_emp_err(v_admin, v, 'سالممحمدعلي');
  perform pg_temp.ok(s = 'name_mismatch', 'the words glued together are not the name', s);
  s := pg_temp.del_emp_err(v_admin, v, (select employee_number from public.employees where id = v));
  perform pg_temp.ok(s = 'name_mismatch', 'the employee number is not the name', s);
  s := pg_temp.del_emp_err(v_admin, v, (select full_name from public.employees where id = em[9]));
  perform pg_temp.ok(s = 'name_mismatch', 'the name of another employee is not the name', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = v), 'after all those wrong names he is untouched');

  -- an open session
  ev := pg_temp.mk_open(v, v_tz, v_today - 1, '08:00');
  s := pg_temp.del_emp_err(v_admin, v, 'اسم خاطئ');
  perform pg_temp.ok(s = 'name_mismatch', 'the name is checked before the open session', s);
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'open_session', 'an open session (he has not left): open_session', s);
  -- ... and a pending request: the open session is named first
  rq := pg_temp.mk_leave(v, v_comp, v_tz, v_today + 10, v_today + 11, 'pending');
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'open_session', 'open_session comes before pending_requests', s);
  delete from public.attendance_sessions where check_in_event_id = ev;
  delete from public.attendance_events where id = ev;
  -- a session waiting for its check-out is history, not "open"
  ev := pg_temp.mk_flagged(v, v_tz, v_today - 3, '08:00');
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'pending_requests', 'a session that waits for its check-out (flagged) does not block; the pending request does', s);

  -- a pending request
  update public.requests set status = 'approved', decided_at = now() where id = rq;
  update public.request_approvals set status = 'approved' where request_id = rq;
  -- a second request that is still pending, from a "permission" or a leave of another type
  rq := pg_temp.mk_leave(v, v_comp, v_tz, v_today + 20, v_today + 20, 'pending');
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'pending_requests', 'a pending request: pending_requests (an approved one does not count)', s);
  update public.requests set status = 'rejected', decided_at = now() where id = rq;
  rq := pg_temp.mk_leave(v, v_comp, v_tz, v_today + 30, v_today + 30, 'pending');
  update public.requests set status = 'cancelled' where id = rq;
  -- a report (a direct report is an employee whose manager he is)
  update public.employees set manager_id = v where id = em[9];
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'has_reports', 'rejected and cancelled requests do not block; someone reports to him: has_reports', s);
  update public.employees set is_active = false where id = em[9];
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'has_reports', 'an inactive employee who reports to him still counts', s);
  -- he approves requests by name in a chain
  update public.employees set manager_id = null where id = em[9];
  insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id)
  values (v_comp, 'leave', 2, 'specific_employee', v) returning id into st;
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'is_approver', 'he is a named approver in a chain: is_approver', s);
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = v), 'every refusal left him untouched');
  perform pg_temp.ok(not exists (select 1 from public.audit_log a where a.action = 'employee.delete' and a.target_id = v::text), 'and none of them wrote an audit row');
  delete from public.approval_steps where id = st;

  -- order of the later two: reports before approver
  update public.employees set manager_id = v where id = em[9];
  insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id)
  values (v_comp, 'leave', 2, 'specific_employee', v) returning id into st;
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'has_reports', 'has_reports comes before is_approver', s);
  delete from public.approval_steps where id = st;
  update public.employees set manager_id = null where id = em[9];

  -- a report who is deleted no longer blocks
  update public.employees set manager_id = em[13] where id = em[14];
  s := pg_temp.del_emp_err(v_admin, em[13], (select full_name from public.employees where id = em[13]));
  perform pg_temp.ok(s = 'has_reports', 'setup: em14 reports to em13', s);
  update public.employees set is_active = false, deleted_at = now() where id = em[14];
  r := pg_temp.del_emp(v_admin, em[13], (select full_name from public.employees where id = em[13]));
  perform pg_temp.ok(r ->> 'deleted' = 'true', 'a deleted report does not count: the manager can be deleted', r::text);

  perform pg_temp.ok(true, 'END part 2');
end
$tests$;

-- =====================================================================================================================
-- PART 3: deleting an employee: the success path and what it leaves behind
-- =====================================================================================================================
do $tests$
declare
  v_admin uuid; v_comp uuid; v_tz text; v_today date;
  em uuid[]; p2 uuid; v uuid; v_name text; v_num text; typed text; r jsonb; s text; n int; ev uuid; sid uuid;
  c_ev int; c_se int; c_rq int; n_all int; k2 int; q record; rr jsonb;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  v_today := (now() at time zone v_tz)::date;
  select array_agg(x.id order by x.employee_number) into em
  from (select e.id, e.employee_number from public.employees e where e.id <> v_admin and e.company_id = v_comp order by e.employee_number limit 20) x;
  select id into p2 from public.work_locations where company_id = v_comp and name = 'مكتب' and deleted_at is null;
  v := em[7];
  select full_name, employee_number into v_name, v_num from public.employees where id = v;

  -- history of the employee: two finished days, one day waiting for its check-out (part 2), three requests of part 2 (approved, rejected, cancelled)
  perform pg_temp.mk_day(v, v_tz, v_today - 5, '08:00', '16:00');
  perform pg_temp.mk_day(v, v_tz, v_today - 4, '08:10', '15:50');
  -- (the flagged check-in of day -3 is already there from part 2)
  -- his phone binding, his login by fingerprint, his push subscriptions
  insert into public.webauthn_credentials (company_id, employee_id, credential_id, public_key, device_label)
  values (v_comp, v, 'cred-delete-test', '\x01'::bytea, 'هاتف');
  insert into public.employee_devices (employee_id, company_id, key_hash) values (v, v_comp, 'hash-delete-test');
  sid := gen_random_uuid();
  insert into private.device_sessions (session_id, employee_id) values (sid, v);
  insert into public.push_subscriptions (user_id, company_id, endpoint, p256dh, auth) values
    (v, v_comp, 'https://push.example/delete-1', repeat('k', 87), repeat('a', 22)), (v, v_comp, 'https://push.example/delete-2', repeat('k', 87), repeat('a', 22)),
    (em[1], v_comp, 'https://push.example/other-1', repeat('k', 87), repeat('a', 22));
  select count(*) into c_ev from public.attendance_events where employee_id = v;
  select count(*) into c_se from public.attendance_sessions where employee_id = v;
  select count(*) into c_rq from public.requests where employee_id = v;
  perform pg_temp.ok(c_ev = 5 and c_se = 3 and c_rq = 3, 'setup: he has history (5 events, 3 sessions, 3 requests)', row(c_ev, c_se, c_rq)::text);

  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n from public.admin_list_employees();
  reset role;

  -- the name is compared after trim, collapsing spaces and Unicode normalisation
  typed := '   ' || replace(v_name, ' ', E'  \t ') || '  ';
  r := pg_temp.del_emp(v_admin, v, typed);
  perform pg_temp.ok(r = '{"deleted": true}'::jsonb, 'extra spaces around and between the words are fine: {deleted: true}', r::text);

  perform pg_temp.ok((select deleted_at is not null and not is_active and employee_number = v_num and full_name = v_name from public.employees where id = v),
                     'the row stays: deleted_at set, inactive, same number and name (the number stays reserved)');
  perform pg_temp.ok((select count(*) = 1 from auth.users where id = v), 'his login account stays (the e-mail stays reserved)');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select count(*) into n_all from public.admin_list_employees();
  select count(*) into n from public.admin_list_employees() x where x.id = v;
  reset role;
  perform pg_temp.ok(n = 0, 'admin_list_employees no longer shows him');
  perform pg_temp.ok(n_all >= 60, 'and still shows everybody else', n_all::text);

  -- nothing of his history is gone, and it still names him (Review Focus 3)
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = v) = c_ev
                     and (select count(*) from public.attendance_sessions where employee_id = v) = c_se
                     and (select count(*) from public.requests where employee_id = v) = c_rq, 'no event, session or request was deleted');
  set local role authenticated;
  select count(*), min(x.full_name), bool_and(x.employee_number = v_num) into q from public.admin_list_attendance(null, null, v, null, 100, 0) x;
  reset role;
  perform pg_temp.ok(q.count = c_ev and q.min = v_name and q.bool_and, 'admin_list_attendance still returns all his events, with his name and number', row(q.count, q.min)::text);
  set local role authenticated;
  rr := public.admin_list_requests(null, 'leave', v, 50, 0);
  reset role;
  perform pg_temp.ok((rr ->> 'total')::int = c_rq and rr -> 'items' -> 0 -> 'employee' ->> 'full_name' = v_name,
                     'admin_list_requests still returns his requests, with his name', left(rr::text, 200));
  set local role authenticated;
  select * into q from public.admin_review_queue(200) x where x.employee_id = v;
  reset role;
  perform pg_temp.ok(q.event_id is not null and q.missed_checkout and q.full_name = v_name, 'his flagged check-in is still in the review queue, with his name');

  -- the phone, the fingerprint, the push
  perform pg_temp.ok(not exists (select 1 from public.webauthn_credentials where employee_id = v)
                     and not exists (select 1 from public.employee_devices where employee_id = v)
                     and not exists (select 1 from private.device_sessions where employee_id = v), 'his phone binding, fingerprint login and device sessions are gone');
  perform pg_temp.ok(exists (select 1 from private.device_unbinds where employee_id = v), 'an unbind marker was written (his old sessions are cut)');
  perform pg_temp.ok(not exists (select 1 from public.push_subscriptions where user_id = v), 'his push subscriptions are gone');
  perform pg_temp.ok((select count(*) = 1 from public.push_subscriptions where user_id = em[1]), 'the subscriptions of another employee are untouched');

  -- he cannot use the app
  perform pg_temp.as_user(v);
  set local role authenticated;
  s := pg_temp.err('select * from public.employee_attendance_state()');
  reset role;
  perform pg_temp.ok(s = 'employee_inactive', 'his attendance state raises employee_inactive (no punch, no usable state)', s);

  -- audit
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'employee.delete' and a.target_type = 'employee' and a.target_id = v::text
                             and a.company_id = v_comp and a.actor_id = v_admin and a.details ->> 'employee_number' = v_num and a.details ->> 'full_name' = v_name),
                     'one audit row: employee.delete with his number and name');
  perform pg_temp.ok((select not (a.details ? 'base_salary') and not (a.details ? 'salary') from public.audit_log a where a.action = 'employee.delete' and a.target_id = v::text),
                     'the audit row carries no salary');

  -- he cannot come back by the back door
  s := pg_temp.del_emp_err(v_admin, v, v_name);
  perform pg_temp.ok(s = 'not_found', 'deleting him again: not_found', s);
  s := pg_temp.save_prof_err(v_admin, v, p2, true);
  perform pg_temp.ok(s like '%employees_deleted_inactive_chk%', 'saving his profile as active does not bring him back', s);
  perform pg_temp.ok((select deleted_at is not null and not is_active from public.employees where id = v), 'he is still deleted and inactive');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_add_admin(%L)', v));
  reset role;
  perform pg_temp.ok(s <> '', 'he cannot be made an admin', s);

  -- the review item of a deleted employee can still be settled
  select e.id into ev from public.attendance_events e join public.attendance_sessions x on x.check_in_event_id = e.id where e.employee_id = v and x.status = 'missed_checkout' limit 1;
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  rr := public.admin_resolve_review(ev, 'accept', null, 'تمت المراجعة');
  reset role;
  perform pg_temp.ok(rr ->> 'action' = 'accept', 'the admin can still accept the flagged check-in of a deleted employee', rr::text);

  -- a second employee: the admin role removed first, then deleted
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_remove_admin(em[8]);
  reset role;
  r := pg_temp.del_emp(v_admin, em[8], (select full_name from public.employees where id = em[8]));
  perform pg_temp.ok(r ->> 'deleted' = 'true', 'a former admin (role removed) can be deleted', r::text);
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'employee.delete' and a.target_id = em[8]::text), 'with his own audit row');

  -- a third: a manager whose reports were deleted, with a closed session
  update public.employees set manager_id = em[11] where id = em[12];
  s := pg_temp.del_emp_err(v_admin, em[11], (select full_name from public.employees where id = em[11]));
  perform pg_temp.ok(s = 'has_reports', 'a manager with a report cannot be deleted', s);
  update public.employees set manager_id = null where id = em[12];
  -- the counts of his place drop when he is deleted
  update public.employees set work_location_id = p2 where id = em[11];
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select x.employees_count, x.active_count into q from public.admin_list_work_locations() x where x.id = p2;
  reset role;
  n := q.employees_count; k2 := q.active_count;
  -- typed with the alef and the hamza as two characters (U+0627 U+0654), the way some keyboards and pasted text give it
  s := pg_temp.del_emp_err(v_admin, em[11], E'\u0627\u0654مل ');
  perform pg_temp.ok(s = 'name_mismatch', 'the name must still be complete (the surname is missing)', s);
  r := pg_temp.del_emp(v_admin, em[11], E'\u0627\u0654مل   حسن');
  perform pg_temp.ok(r ->> 'deleted' = 'true', 'after the report is moved away he can be; the letter typed in two pieces equals the one-piece letter (normalisation)', r::text);
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select x.employees_count, x.active_count into q from public.admin_list_work_locations() x where x.id = p2;
  reset role;
  perform pg_temp.ok(q.employees_count = n - 1 and q.active_count = k2 - 1, 'his place no longer counts him (employees_count and active_count both drop by one)', row(n, k2, q.employees_count, q.active_count)::text);

  -- the platform list counts only people who are not deleted
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select x.employees_count into n from public.platform_list_companies() x where x.id = v_comp;
  reset role;
  perform pg_temp.ok(n = (select count(*) from public.employees where company_id = v_comp and deleted_at is null)
                     and n < (select count(*) from public.employees where company_id = v_comp), 'platform_list_companies counts only employees who are not deleted', n::text);

  perform pg_temp.ok(true, 'END part 3');
end
$tests$;

-- =====================================================================================================================
-- PART 4: two admins at the same time (row locks). Needs dblink: a second and a third session, each in its own transaction.
-- =====================================================================================================================
create extension if not exists dblink;
-- a second session, in a transaction, as the admin (security definer functions see auth.uid() from the claims)
create function pg_temp.open_admin(conn text, adm uuid) returns void language plpgsql as $$
begin
  perform dblink_connect(conn, 'dbname=' || current_database());
  perform dblink_exec(conn, 'begin');
  perform * from dblink(conn, format('select set_config(%L, %L, true)', 'request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text)) as t(x text);
  perform dblink_exec(conn, 'set local role authenticated');
end $$;
-- a second session, in a transaction, with the table owner's rights (an update done directly)
create function pg_temp.open_plain(conn text) returns void language plpgsql as $$
begin
  perform dblink_connect(conn, 'dbname=' || current_database());
  perform dblink_exec(conn, 'begin');
end $$;
create function pg_temp.backend_pid(conn text) returns int language sql as
  $$ select p from dblink(conn, 'select pg_backend_pid()') as t(p int) $$;
-- wait (at most about 4 s) until that backend is waiting for a lock
create function pg_temp.wait_blocked(p int) returns boolean language plpgsql as $$
declare w text; i int := 0;
begin
  loop
    perform pg_stat_clear_snapshot();   -- inside one transaction pg_stat_activity would otherwise show the first reading again
    select a.wait_event_type into w from pg_stat_activity a where a.pid = p;
    exit when w = 'Lock' or i >= 80;
    perform pg_sleep(0.05);
    i := i + 1;
  end loop;
  return w = 'Lock';
end $$;
-- the answer of the query sent without waiting: its one text value, or 'ERR:' and the error text
create function pg_temp.finish(conn text) returns text language plpgsql as $$
declare r text;
begin
  begin
    select x into r from dblink_get_result(conn) as t(x text);
  exception when others then
    r := 'ERR:' || sqlerrm;
  end;
  begin
    perform * from dblink_get_result(conn) as t(x text);
  exception when others then null;
  end;
  return r;
end $$;
create function pg_temp.close_both(c1 text, c2 text) returns void language plpgsql as $$
begin
  begin perform dblink_exec(c1, 'commit'); exception when others then null; end;
  begin perform dblink_exec(c2, 'commit'); exception when others then null; end;
  begin perform dblink_disconnect(c1); exception when others then null; end;
  begin perform dblink_disconnect(c2); exception when others then null; end;
end $$;

-- the data the other sessions must see: committed here, before the race block
do $tests$
declare
  v_admin uuid; v_comp uuid; em uuid[]; x uuid; k int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select array_agg(y.id order by y.employee_number) into em
  from (select e.id, e.employee_number from public.employees e where e.id <> v_admin and e.company_id = v_comp order by e.employee_number limit 20) y;
  for k in 1..5 loop
    insert into t_ids values ('x' || k, pg_temp.add_loc(v_admin, 'سباق ' || k));
  end loop;
  insert into t_ids values ('target', pg_temp.add_loc(v_admin, 'سباق هدف'));
  for k in 16..20 loop
    update public.employees set is_active = true, deleted_at = null, manager_id = null, work_location_id = null where id = em[k];
    insert into t_ids values ('e' || k, em[k]);
  end loop;
  perform pg_temp.ok((select count(*) = 11 from t_ids), 'race setup: 6 places and 5 employees, committed');
  perform pg_temp.ok(true, 'END part 4a');
end
$tests$;

do $tests$
declare
  v_admin uuid; v_comp uuid; x1 uuid; x2 uuid; x3 uuid; x4 uuid; x5 uuid; t uuid; e16 uuid; e17 uuid; e18 uuid; e19 uuid; e20 uuid;
  pid int; blocked boolean; res text; v_name text;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into x1 from t_ids where k = 'x1'; select id into x2 from t_ids where k = 'x2'; select id into x3 from t_ids where k = 'x3';
  select id into x4 from t_ids where k = 'x4'; select id into x5 from t_ids where k = 'x5'; select id into t from t_ids where k = 'target';
  select id into e16 from t_ids where k = 'e16'; select id into e17 from t_ids where k = 'e17'; select id into e18 from t_ids where k = 'e18';
  select id into e19 from t_ids where k = 'e19'; select id into e20 from t_ids where k = 'e20';

  -- R1: A moves an employee into an empty place (not committed yet); B deletes that place. B must wait, then see the employee.
  perform pg_temp.open_plain('c1');
  perform dblink_exec('c1', format('update public.employees set work_location_id = %L where id = %L', x1, e17));
  perform pg_temp.open_admin('c2', v_admin);
  pid := pg_temp.backend_pid('c2');
  perform dblink_send_query('c2', format('select public.admin_delete_work_location(%L, null)::text', x1));
  blocked := pg_temp.wait_blocked(pid);
  perform pg_temp.ok(blocked, 'R1: the delete of a place waits for an uncommitted move into it');
  perform dblink_exec('c1', 'commit');
  res := pg_temp.finish('c2');
  perform pg_temp.ok(res = 'ERR:has_employees', 'R1: after the move commits, the delete sees the employee: has_employees', res);
  perform pg_temp.close_both('c1', 'c2');
  perform pg_temp.ok((select deleted_at is null from public.work_locations where id = x1) and (select work_location_id = x1 from public.employees where id = e17),
                     'R1: the place is live and the employee is in it');

  -- R2: B deletes an empty place (not committed yet); A then moves an employee into it. A must wait, then be refused.
  perform pg_temp.open_admin('c1', v_admin);
  perform * from dblink('c1', format('select public.admin_delete_work_location(%L, null)::text', x2)) as r(x text);
  perform pg_temp.open_plain('c2');
  pid := pg_temp.backend_pid('c2');
  perform dblink_send_query('c2', format('with u as (update public.employees set work_location_id = %L where id = %L returning 1) select count(*)::text from u', x2, e18));
  blocked := pg_temp.wait_blocked(pid);
  perform pg_temp.ok(blocked, 'R2: a move into a place waits for the uncommitted delete of that place');
  perform dblink_exec('c1', 'commit');
  res := pg_temp.finish('c2');
  perform pg_temp.ok(res = 'ERR:invalid_work_location', 'R2: after the delete commits the move is refused: invalid_work_location', res);
  perform pg_temp.close_both('c1', 'c2');
  perform pg_temp.ok((select deleted_at is not null from public.work_locations where id = x2) and (select work_location_id is null from public.employees where id = e18),
                     'R2: the place is deleted and nobody was put in it');

  -- R3: two admins delete the same employee. The second waits, then finds him already gone.
  select full_name into v_name from public.employees where id = e19;
  perform pg_temp.open_admin('c1', v_admin);
  perform * from dblink('c1', format('select public.admin_delete_employee(%L, %L)::text', e19, v_name)) as r(x text);
  perform pg_temp.open_admin('c2', v_admin);
  pid := pg_temp.backend_pid('c2');
  perform dblink_send_query('c2', format('select public.admin_delete_employee(%L, %L)::text', e19, v_name));
  blocked := pg_temp.wait_blocked(pid);
  perform pg_temp.ok(blocked, 'R3: the second delete of the same employee waits for the first');
  perform dblink_exec('c1', 'commit');
  res := pg_temp.finish('c2');
  perform pg_temp.ok(res = 'ERR:not_found', 'R3: and then finds nobody: not_found', res);
  perform pg_temp.close_both('c1', 'c2');
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'employee.delete' and a.target_id = e19::text), 'R3: one audit row, not two');

  -- R4: two admins delete the same place.
  perform pg_temp.open_admin('c1', v_admin);
  perform * from dblink('c1', format('select public.admin_delete_work_location(%L, null)::text', x4)) as r(x text);
  perform pg_temp.open_admin('c2', v_admin);
  pid := pg_temp.backend_pid('c2');
  perform dblink_send_query('c2', format('select public.admin_delete_work_location(%L, null)::text', x4));
  blocked := pg_temp.wait_blocked(pid);
  perform pg_temp.ok(blocked, 'R4: the second delete of the same place waits for the first');
  perform dblink_exec('c1', 'commit');
  res := pg_temp.finish('c2');
  perform pg_temp.ok(res = 'ERR:not_found', 'R4: and then finds no live place: not_found', res);
  perform pg_temp.close_both('c1', 'c2');
  perform pg_temp.ok((select count(*) = 1 from public.audit_log a where a.action = 'work_location.delete' and a.target_id = x4::text), 'R4: one audit row, not two');

  -- R5: B deletes a place with a target while A moves an employee into it. The employee ends up at the target, counted.
  perform pg_temp.open_plain('c1');
  perform dblink_exec('c1', format('update public.employees set work_location_id = %L where id = %L', x5, e20));
  perform pg_temp.open_admin('c2', v_admin);
  pid := pg_temp.backend_pid('c2');
  perform dblink_send_query('c2', format('select public.admin_delete_work_location(%L, %L)::text', x5, t));
  blocked := pg_temp.wait_blocked(pid);
  perform pg_temp.ok(blocked, 'R5: the delete waits for the uncommitted move');
  perform dblink_exec('c1', 'commit');
  res := pg_temp.finish('c2');
  perform pg_temp.ok(res::jsonb = '{"deleted": true, "moved": 1}'::jsonb, 'R5: and moves that employee too: moved 1', res);
  perform pg_temp.close_both('c1', 'c2');
  perform pg_temp.ok((select work_location_id = t from public.employees where id = e20) and (select deleted_at is not null from public.work_locations where id = x5),
                     'R5: nobody is left at the deleted place');

  -- R6: an admin is made while another admin deletes him. The delete waits and then refuses (he is an admin now).
  select full_name into v_name from public.employees where id = e16;
  perform pg_temp.open_admin('c1', v_admin);
  perform * from dblink('c1', format('select public.admin_add_admin(%L)::text', e16)) as r(x text);
  perform pg_temp.open_admin('c2', v_admin);
  pid := pg_temp.backend_pid('c2');
  perform dblink_send_query('c2', format('select public.admin_delete_employee(%L, %L)::text', e16, v_name));
  blocked := pg_temp.wait_blocked(pid);
  perform pg_temp.ok(blocked, 'R6: the delete waits for an uncommitted admin promotion of the same employee');
  perform dblink_exec('c1', 'commit');
  res := pg_temp.finish('c2');
  perform pg_temp.ok(res = 'ERR:is_admin', 'R6: and then refuses: is_admin', res);
  perform pg_temp.close_both('c1', 'c2');
  perform pg_temp.ok((select deleted_at is null and is_active from public.employees where id = e16), 'R6: he is not deleted');

  perform pg_temp.ok(true, 'END part 4');
end
$tests$;

do $report$
declare v text;
begin
  -- a block that stopped on an error must show as a failure, not as fewer passes
  insert into t_res (name, ok, detail)
  select 'part ' || blk.k || ' did not finish', false, 'a block stopped on an error' from (values ('1'), ('2'), ('3'), ('4a'), ('4')) blk(k)
  where not exists (select 1 from t_res where t_res.name = 'END part ' || blk.k);
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
