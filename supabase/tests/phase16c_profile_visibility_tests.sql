-- Phase 16c: the employee's own data summary, with company switches for what he may see.
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
create function pg_temp.as_user(u uuid, app jsonb default '{}') returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'app_metadata', app)::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.try_as(u uuid, q text, app jsonb default '{}') returns text language plpgsql as $$
declare s text;
begin
  perform pg_temp.as_user(u, app);
  set local role authenticated;
  s := pg_temp.err(q);
  reset role;
  return s;
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
-- the summary of user u
create function pg_temp.summ(u uuid) returns jsonb language sql as $$ select pg_temp.run_as(u, 'select public.employee_profile_summary()') $$;
-- the admin sets the switches
create function pg_temp.vis(u uuid, v jsonb) returns jsonb language sql as
  $$ select pg_temp.run_as(u, format('select public.admin_set_profile_visibility(%L::jsonb)', v)) $$;
create function pg_temp.all_keys(on_ boolean) returns jsonb language sql as $$
  select jsonb_object_agg(k, on_) from unnest(array['department','job_title','work_location','hire_date','schedule','leave',
    'salary_base','salary_components','salary_total','birth_date','gender']) k $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_comp2 uuid; e2 uuid; r jsonb; r2 jsonb; s text; n int; k text; v_loc uuid;
  sensitive text[] := array['salary', 'birth_date', 'gender'];
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;

  -- fixture: A has every kind of data
  insert into public.work_locations (name, company_id) values ('المقر الرئيسي', v_comp) returning id into v_loc;
  update public.employees set department = 'المبيعات', job_title = 'محاسب', work_location_id = v_loc, hire_date = '2022-03-01',
         birth_date = '1990-05-02', gender = 'male' where id = a;
  insert into public.employee_compensation (employee_id, base_salary, company_id) values (a, 1500, v_comp)
    on conflict (employee_id) do update set base_salary = 1500;
  delete from public.employee_salary_components where employee_id = a;
  insert into public.employee_salary_components (employee_id, name, amount, sort_order, company_id)
  values (a, 'بدل سكن', 200, 1, v_comp), (a, 'بدل نقل', 50, 2, v_comp);
  delete from public.audit_log where action = 'company.profile_visibility';

  -- ---------------------------------------------------------------- grants
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.employee_profile_summary()', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_get_profile_visibility()', 'execute')
                     and has_function_privilege('authenticated', 'public.admin_set_profile_visibility(jsonb)', 'execute'),
                     'signed-in users can call the three functions');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.employee_profile_summary()', 'execute')
                     and not has_function_privilege('anon', 'public.admin_get_profile_visibility()', 'execute')
                     and not has_function_privilege('anon', 'public.admin_set_profile_visibility(jsonb)', 'execute')
                     and not has_function_privilege('anon', 'public.get_my_profile()', 'execute'),
                     'anonymous visitors cannot');

  -- ---------------------------------------------------------------- 1. defaults
  r := pg_temp.summ(a);
  perform pg_temp.ok(r -> 'employee' ->> 'department' = 'المبيعات' and r -> 'employee' ->> 'job_title' = 'محاسب'
                     and r -> 'employee' ->> 'work_location_name' = 'المقر الرئيسي' and r -> 'employee' ->> 'hire_date' = '2022-03-01'
                     and jsonb_array_length(r -> 'schedule') = 7 and jsonb_array_length(r -> 'leave') >= 1,
                     'defaults: job, location, hire date, schedule and leave are shown', r::text);
  perform pg_temp.ok(not (r ? 'salary') and not (r -> 'employee' ? 'birth_date') and not (r -> 'employee' ? 'gender'),
                     'defaults: no salary, no birth date, no gender (keys absent)', r::text);
  perform pg_temp.ok(r::text !~ '1500|1990-05-02|بدل سكن', 'defaults: the hidden values are not anywhere in the text', r::text);
  r := pg_temp.run_as(v_admin, 'select public.admin_get_profile_visibility()');
  perform pg_temp.ok(r = '{"department": true, "job_title": true, "work_location": true, "hire_date": true, "schedule": true, "leave": true,
                           "salary_base": false, "salary_components": false, "salary_total": false, "birth_date": false, "gender": false}'::jsonb,
                     'admin sees the 11 defaults', r::text);

  -- ---------------------------------------------------------------- 3. all on / all off
  r := pg_temp.vis(v_admin, pg_temp.all_keys(true));
  r := pg_temp.summ(a);
  perform pg_temp.ok((r -> 'salary' ->> 'base_salary')::numeric = 1500 and jsonb_array_length(r -> 'salary' -> 'components') = 2
                     and (r -> 'salary' ->> 'total')::numeric = 1750
                     and r -> 'employee' ->> 'birth_date' = '1990-05-02' and r -> 'employee' ->> 'gender' = 'male',
                     'all on: full record, total = base + components', r::text);
  r := pg_temp.vis(v_admin, pg_temp.all_keys(false));
  r := pg_temp.summ(a);
  perform pg_temp.ok(r = '{}'::jsonb or r = '{"employee": {}}'::jsonb, 'all off: nothing optional', r::text);

  -- ---------------------------------------------------------------- 2. each key alone
  for k in select unnest(array['department','job_title','work_location','hire_date','schedule','leave',
                               'salary_base','salary_components','salary_total','birth_date','gender']) loop
    perform pg_temp.vis(v_admin, pg_temp.all_keys(false) || jsonb_build_object(k, true));
    r := pg_temp.summ(a);
    perform pg_temp.ok(
      case k
        when 'department' then r -> 'employee' ? 'department' and (select count(*) from jsonb_object_keys(r -> 'employee')) = 1 and not r ? 'salary'
        when 'job_title' then r -> 'employee' ? 'job_title' and (select count(*) from jsonb_object_keys(r -> 'employee')) = 1 and not r ? 'salary'
        when 'work_location' then r -> 'employee' ? 'work_location_name' and (select count(*) from jsonb_object_keys(r -> 'employee')) = 1
        when 'hire_date' then r -> 'employee' ? 'hire_date' and (select count(*) from jsonb_object_keys(r -> 'employee')) = 1
        when 'schedule' then r ? 'schedule' and not r ? 'leave' and not r ? 'salary'
        when 'leave' then r ? 'leave' and not r ? 'schedule' and not r ? 'salary'
        when 'salary_base' then r -> 'salary' ? 'base_salary' and not r -> 'salary' ? 'components' and not r -> 'salary' ? 'total'
        when 'salary_components' then r -> 'salary' ? 'components' and not r -> 'salary' ? 'base_salary' and not r -> 'salary' ? 'total'
        when 'salary_total' then r -> 'salary' ? 'total' and not r -> 'salary' ? 'base_salary' and not r -> 'salary' ? 'components'
        when 'birth_date' then r -> 'employee' ? 'birth_date' and (select count(*) from jsonb_object_keys(r -> 'employee')) = 1 and not r ? 'salary'
        when 'gender' then r -> 'employee' ? 'gender' and (select count(*) from jsonb_object_keys(r -> 'employee')) = 1 and not r ? 'salary'
      end, format('only "%s" on: exactly that item', k), r::text);
  end loop;

  -- 4. only the total: the base is absent (not null)
  perform pg_temp.vis(v_admin, pg_temp.all_keys(false) || '{"salary_total": true}');
  r := pg_temp.summ(a);
  perform pg_temp.ok(r::text !~ 'base_salary' and r::text !~ '"1500' and (r -> 'salary' ->> 'total')::numeric = 1750,
                     'total only: base and components do not appear at all', r::text);

  -- ---------------------------------------------------------------- 5. the old door
  perform pg_temp.vis(v_admin, '{"department": true, "job_title": true, "work_location": true, "hire_date": true, "schedule": true,
    "leave": true, "salary_base": false, "salary_components": false, "salary_total": false, "birth_date": false, "gender": false}');
  r := pg_temp.run_as(a, 'select public.get_my_profile()');
  r2 := pg_temp.summ(a);
  perform pg_temp.ok(r = r2 and not r ? 'salary', 'get_my_profile() = the filtered summary (no salary by default)', r::text);

  -- ---------------------------------------------------------------- 8. merge and audit
  delete from public.audit_log where action = 'company.profile_visibility';
  r := pg_temp.vis(v_admin, '{"gender": true}');
  perform pg_temp.ok(r ->> 'gender' = 'true' and r ->> 'department' = 'true' and r ->> 'salary_total' = 'false',
                     'one key sent: the others keep their value', r::text);
  select count(*) into n from public.audit_log where action = 'company.profile_visibility'
     and details -> 'changed' -> 'gender' = '{"from": false, "to": true}'::jsonb and company_id = v_comp;
  perform pg_temp.ok(n = 1, 'audit row with from/to', n::text);
  r := pg_temp.vis(v_admin, '{"gender": true}');
  select count(*) into n from public.audit_log where action = 'company.profile_visibility';
  perform pg_temp.ok(n = 1, 'no change: no audit row', n::text);

  -- ---------------------------------------------------------------- 7. bad input
  for s in select unnest(array['{"salary": true}', '{"gender": "yes"}', '[true]', '"x"', '{"gender": null}']) loop
    perform pg_temp.ok(pg_temp.try_as(v_admin, format('select public.admin_set_profile_visibility(%L::jsonb)', s)) = 'invalid_profile_visibility',
                       'refused: ' || s);
  end loop;
  perform pg_temp.ok(pg_temp.try_as(v_admin, 'select public.admin_set_profile_visibility(null)') = 'invalid_profile_visibility', 'refused: null');
  r := pg_temp.run_as(v_admin, 'select public.admin_get_profile_visibility()');
  perform pg_temp.ok(r ->> 'gender' = 'true' and r ->> 'salary_total' = 'false', 'after refused calls nothing changed', r::text);

  -- ---------------------------------------------------------------- 6. who may do what
  s := pg_temp.try_as(a, 'select public.admin_get_profile_visibility()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot read the switches', s);
  s := pg_temp.try_as(a, 'select public.admin_set_profile_visibility(''{"salary_total": true}''::jsonb)');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot change the switches', s);
  s := pg_temp.try_as(v_admin, 'select public.admin_get_profile_visibility()', '{"must_change_password": true}');
  perform pg_temp.ok(s <> '', 'admin with a temporary password is refused', s);
  r := pg_temp.summ(b);
  perform pg_temp.ok(r::text !~ 'المبيعات|محاسب|المقر الرئيسي', 'B never gets A''s data', r::text);
  s := pg_temp.try_as(a, 'select public.employee_profile_summary()', '{"must_change_password": true}');
  perform pg_temp.ok(s = 'must_change_password', 'temporary password: the summary is refused', s);

  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار الظهور', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'vis-iso@example.com', jsonb_build_object('company_id', v_comp2, 'company_role', 'company_admin'), '{"full_name":"مدير شركة أخرى"}')
  returning id into e2;
  r := pg_temp.vis(e2, pg_temp.all_keys(true));
  r := pg_temp.summ(a);
  perform pg_temp.ok(not r ? 'salary', 'the other company''s admin does not change this company', r::text);
  r := pg_temp.run_as(e2, 'select public.admin_get_profile_visibility()');
  perform pg_temp.ok(r ->> 'salary_total' = 'true', '... only his own', r::text);

  -- ---------------------------------------------------------------- 9. inactive
  update public.employees set is_active = false where id = a;
  s := pg_temp.try_as(a, 'select public.employee_profile_summary()');
  perform pg_temp.ok(s <> '', 'inactive employee is refused', s);
  update public.employees set is_active = true where id = a;
  update public.companies set is_active = false where id = v_comp;
  s := pg_temp.try_as(a, 'select public.employee_profile_summary()');
  perform pg_temp.ok(s <> '', 'inactive company is refused', s);
  update public.companies set is_active = true where id = v_comp;

  -- a stored value with an unknown key is ignored (a key removed later must not break the reads)
  update public.companies set profile_visibility = profile_visibility || '{"old_key": true}' where id = v_comp;
  r := pg_temp.run_as(v_admin, 'select public.admin_get_profile_visibility()');
  perform pg_temp.ok(not r ? 'old_key' and (select count(*) from jsonb_object_keys(r)) = 11, 'unknown stored keys are ignored', r::text);
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
