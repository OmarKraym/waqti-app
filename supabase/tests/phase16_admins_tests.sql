-- Phase 16: a company admin lists, adds and removes admins of the same company.
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
-- run a "select <jsonb function>" as the signed-in user u and return the result
create function pg_temp.run_as(u uuid, q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q into r;
  reset role;
  return r;
end $$;
-- the list as the signed-in user u
create function pg_temp.admins_as(u uuid) returns table (id uuid, full_name text, employee_number text, email text,
  is_active boolean, is_me boolean, since timestamptz) language plpgsql as $$
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  return query select * from public.admin_list_admins();
  reset role;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; x uuid; v_comp uuid; v_comp2 uuid; e2 uuid; e2b uuid;
  r jsonb; s text; n int; n2 int; t timestamptz; rec record; v_req_before int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into x from public.employees e where not e.is_active and e.company_id = v_comp order by employee_number limit 1;
  perform pg_temp.ok(a is not null and b is not null and x is not null, 'fixture: two active employees and one inactive employee');
  delete from public.audit_log where action in ('admin.added', 'admin.removed');

  -- ---------------------------------------------------------------- who may call
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_list_admins()', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_add_admin(uuid)', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_remove_admin(uuid)', 'execute'),
                     'signed-in users can call the three functions (the admin check is inside)');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_admins()', 'execute')
                     and not has_function_privilege('anon', 'public.admin_add_admin(uuid)', 'execute')
                     and not has_function_privilege('anon', 'public.admin_remove_admin(uuid)', 'execute'),
                     'anonymous visitors cannot call them');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.working_admin_count(uuid, uuid)', 'execute'),
                     'the counting helper is private');
  s := pg_temp.try_as(b, 'select count(*) from public.admin_list_admins()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot list admins', s);
  s := pg_temp.try_as(b, format('select public.admin_add_admin(%L)', a));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot add an admin', s);
  s := pg_temp.try_as(b, format('select public.admin_remove_admin(%L)', v_admin));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot remove an admin', s);
  s := pg_temp.try_as(v_admin, 'select count(*) from public.admin_list_admins()', '{"must_change_password": true}');
  perform pg_temp.ok(s = 'must_change_password', 'an admin with a temporary password is stopped (list)', s);
  s := pg_temp.try_as(v_admin, format('select public.admin_add_admin(%L)', a), '{"must_change_password": true}');
  perform pg_temp.ok(s = 'must_change_password', 'an admin with a temporary password is stopped (add)', s);
  s := pg_temp.try_as(v_admin, format('select public.admin_remove_admin(%L)', a), '{"must_change_password": true}');
  perform pg_temp.ok(s = 'must_change_password', 'an admin with a temporary password is stopped (remove)', s);

  -- ---------------------------------------------------------------- the list
  select count(*) into n from pg_temp.admins_as(v_admin);
  select * into rec from pg_temp.admins_as(v_admin) q where q.id = v_admin;
  perform pg_temp.ok(n = 1 and rec.is_me and rec.is_active and rec.employee_number = '000' and rec.since is not null
                     and rec.email = 'admin@example.com' and rec.full_name is not null,
                     'the list starts with the one admin: me, active, with number, email and a start time', n::text);

  -- ---------------------------------------------------------------- adding
  r := pg_temp.run_as(v_admin, format('select public.admin_add_admin(%L)', a));
  perform pg_temp.ok(r ->> 'employee_id' = a::text
                     and r ->> 'full_name' = (select e.full_name from public.employees e where e.id = a)
                     and r ->> 'employee_number' = (select e.employee_number from public.employees e where e.id = a),
                     'adding says who was added', r::text);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = a) = 'company_admin'
                     and (select m.company_id from public.company_members m where m.user_id = a) = v_comp,
                     'the employee now has the admin role in the same company');
  perform pg_temp.ok((select count(*) from public.audit_log l where l.action = 'admin.added' and l.target_type = 'employee'
                        and l.target_id = a::text and l.company_id = v_comp and l.actor_id = v_admin
                        and l.details ->> 'employee_number' = (select e.employee_number from public.employees e where e.id = a)) = 1,
                     'one audit row admin.added with the actor, the target and the employee number');
  select count(*) into n from pg_temp.admins_as(v_admin);
  select * into rec from pg_temp.admins_as(v_admin) q where q.id = a;
  perform pg_temp.ok(n = 2 and not rec.is_me and rec.is_active, 'the list now has both admins; the new one is not "me"', n::text);
  perform pg_temp.ok(rec.since > (select m.created_at from public.company_members m where m.user_id = a),
                     'the start time is the time of promotion, not of the account');
  perform pg_temp.ok((select q.id from pg_temp.admins_as(v_admin) q order by q.since, q.full_name limit 1) = v_admin
                     and (select array_agg(q.id order by q.since, q.full_name) from pg_temp.admins_as(v_admin) q)
                         = (select array_agg(q.id) from pg_temp.admins_as(v_admin) q),
                     'the list is ordered by start time, so the first admin comes first');
  s := pg_temp.try_as(a, 'select count(*) from public.admin_list_employees()');
  perform pg_temp.ok(s = '', 'the new admin can use the admin functions at once', s);
  s := pg_temp.try_as(v_admin, format('select public.admin_add_admin(%L)', a));
  perform pg_temp.ok(s = 'already_admin', 'adding an admin again is refused', s);
  s := pg_temp.try_as(v_admin, format('select public.admin_add_admin(%L)', v_admin));
  perform pg_temp.ok(s = 'already_admin', 'adding myself is refused (already an admin)', s);
  s := pg_temp.try_as(v_admin, format('select public.admin_add_admin(%L)', x));
  perform pg_temp.ok(s = 'employee_inactive', 'an inactive employee cannot be made admin', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = x) = 'employee', '... and stays a plain employee');
  s := pg_temp.try_as(v_admin, format('select public.admin_add_admin(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'not_found', 'an unknown person is not found', s);
  s := pg_temp.try_as(v_admin, 'select public.admin_add_admin(null)');
  perform pg_temp.ok(s = 'not_found', 'no person given is not found', s);
  perform pg_temp.ok((select count(*) from public.audit_log l where l.action = 'admin.added') = 1, 'refused adds write no audit row');

  -- ---------------------------------------------------------------- removing
  s := pg_temp.try_as(v_admin, format('select public.admin_remove_admin(%L)', v_admin));
  perform pg_temp.ok(s = 'cannot_remove_self', 'an admin cannot remove himself', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = v_admin) = 'company_admin', '... and is still an admin');
  s := pg_temp.try_as(v_admin, format('select public.admin_remove_admin(%L)', b));
  perform pg_temp.ok(s = 'not_admin', 'removing someone who is not an admin is refused', s);
  s := pg_temp.try_as(v_admin, format('select public.admin_remove_admin(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'not_found', 'removing an unknown person is not found', s);
  s := pg_temp.try_as(v_admin, 'select public.admin_remove_admin(null)');
  perform pg_temp.ok(s = 'not_found', 'removing nobody is not found', s);
  perform pg_temp.ok((select count(*) from public.audit_log l where l.action = 'admin.removed') = 0, 'refused removals write no audit row');

  select count(*) into v_req_before from public.requests q where q.employee_id = a;
  r := pg_temp.run_as(v_admin, format('select public.admin_remove_admin(%L)', a));
  perform pg_temp.ok(r ->> 'employee_id' = a::text and r ->> 'employee_number' is not null, 'removing says who was removed', r::text);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = a) = 'employee',
                     'the role goes back to employee (the membership row stays)');
  perform pg_temp.ok((select e.is_active from public.employees e where e.id = a)
                     and (select count(*) from public.requests q where q.employee_id = a) = v_req_before,
                     'the person is still an active employee with his data');
  perform pg_temp.ok((select count(*) from public.audit_log l where l.action = 'admin.removed' and l.target_id = a::text
                        and l.company_id = v_comp and l.actor_id = v_admin and l.target_type = 'employee') = 1,
                     'one audit row admin.removed');
  s := pg_temp.try_as(a, 'select count(*) from public.admin_list_employees()');
  perform pg_temp.ok(s = 'forbidden', 'the removed admin is stopped at once', s);
  select count(*) into n from pg_temp.admins_as(v_admin);
  perform pg_temp.ok(n = 1, 'the list is back to one admin', n::text);

  -- a promoted admin has the same power: he can remove the first admin, and the first can be added back
  perform pg_temp.run_as(v_admin, format('select public.admin_add_admin(%L)', a));
  r := pg_temp.run_as(a, format('select public.admin_remove_admin(%L)', v_admin));
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = v_admin) = 'employee',
                     'a promoted admin can remove the first admin');
  s := pg_temp.try_as(v_admin, 'select count(*) from public.admin_list_admins()');
  perform pg_temp.ok(s = 'forbidden', '... who is then stopped at once', s);
  perform pg_temp.run_as(a, format('select public.admin_add_admin(%L)', v_admin));
  s := pg_temp.try_as(v_admin, 'select count(*) from public.admin_list_admins()');
  perform pg_temp.ok(s = '', '... and can be added back', s);
  perform pg_temp.ok((select q.since from pg_temp.admins_as(v_admin) q where q.id = v_admin) > (select m.created_at from public.company_members m where m.user_id = v_admin),
                     'added back, his start time is the new promotion, not the account''s age');

  -- ---------------------------------------------------------------- working admins
  perform pg_temp.ok(private.working_admin_count(v_comp, null) = 2, 'two working admins', private.working_admin_count(v_comp, null)::text);
  perform pg_temp.ok(private.working_admin_count(v_comp, a) = 1 and private.working_admin_count(v_comp, v_admin) = 1,
                     'the count can leave one person out');
  -- an admin row of an employee who was switched off is not a working admin
  update public.company_members set role = 'company_admin' where user_id = x;
  perform pg_temp.ok(private.working_admin_count(v_comp, null) = 2, 'an inactive admin is not counted');
  select * into rec from pg_temp.admins_as(v_admin) q where q.id = x;
  perform pg_temp.ok(rec.id is not null and not rec.is_active, 'but the list still shows him, marked inactive');
  s := pg_temp.try_as(v_admin, format('select public.admin_remove_admin(%L)', x));
  perform pg_temp.ok(s = '', 'an inactive admin can be cleaned up', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = x) = 'employee', '... his role is gone');
  -- the last working admin: the other admin is inactive, so nobody is left once the caller is gone
  update public.employees set is_active = false where id = a;
  perform pg_temp.ok(private.working_admin_count(v_comp, v_admin) = 0, 'with the only other admin switched off, nobody else is working');
  update public.employees set is_active = true where id = a;
  perform pg_temp.ok(private.working_admin_count(v_comp, v_admin) = 1, '... and switched on again, one is');

  -- ---------------------------------------------------------------- another company
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار المديرين', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'admins-iso@example.com', jsonb_build_object('company_id', v_comp2, 'company_role', 'company_admin'), '{"full_name":"مدير شركة أخرى"}')
  returning id into e2;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'admins-iso2@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e2b;
  perform pg_temp.ok(private.working_admin_count(v_comp2, null) = 1 and private.working_admin_count(v_comp, null) = 2,
                     'each company counts only its own admins');
  select count(*) into n from pg_temp.admins_as(e2);
  select count(*) into n2 from pg_temp.admins_as(e2) q where q.id = e2 and q.is_me;
  perform pg_temp.ok(n = 1 and n2 = 1, 'the other company''s admin sees only his own company''s admins', n::text);
  select count(*) into n from pg_temp.admins_as(v_admin) q where q.id in (e2, e2b);
  perform pg_temp.ok(n = 0, 'and our list does not show theirs');
  s := pg_temp.try_as(v_admin, format('select public.admin_add_admin(%L)', e2b));
  perform pg_temp.ok(s = 'not_found', 'another company''s employee cannot be made admin by us', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = e2b) = 'employee', '... and is unchanged');
  s := pg_temp.try_as(v_admin, format('select public.admin_remove_admin(%L)', e2));
  perform pg_temp.ok(s = 'not_found', 'another company''s admin cannot be removed by us', s);
  perform pg_temp.ok((select m.role from public.company_members m where m.user_id = e2) = 'company_admin', '... and is unchanged');
  s := pg_temp.try_as(e2, format('select public.admin_add_admin(%L)', b));
  perform pg_temp.ok(s = 'not_found', 'and they cannot make our employee admin', s);
  s := pg_temp.try_as(e2, format('select public.admin_remove_admin(%L)', v_admin));
  perform pg_temp.ok(s = 'not_found', 'nor remove our admin', s);
  s := pg_temp.try_as(e2, format('select public.admin_add_admin(%L)', e2b));
  perform pg_temp.ok(s = '', 'in their own company it works', s);
  perform pg_temp.ok((select count(*) from public.audit_log l where l.action = 'admin.added' and l.company_id = v_comp2) = 1
                     and (select count(*) from public.audit_log l where l.action = 'admin.added' and l.company_id = v_comp) = 3,
                     'audit rows carry the right company');

  -- final state of our company
  perform pg_temp.ok((select count(*) from public.company_members m where m.company_id = v_comp and m.role = 'company_admin') = 2
                     and (select m.role from public.company_members m where m.user_id = v_admin) = 'company_admin',
                     'our company ends with the two admins we expect');
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
