-- Fix 2026-11-26: «create employee» in the admin panel always failed with create_failed (500).
-- Supabase Auth's admin createUser INSERTs the user with app_metadata = {provider, providers} only, and writes the custom
-- app_metadata (company_id, company_role) with an UPDATE afterwards in the same transaction. The trigger ran only AFTER INSERT,
-- so it never saw company_id and created no employee row; admin_save_employee_profile then said employee_not_found.
-- These tests imitate that exact order (insert, then update) and also check that nothing changes for existing accounts.
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
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
-- What createUser does: insert with the provider only, then merge the custom app_metadata in.
create function pg_temp.gotrue_create(p_email text, p_app jsonb, p_user jsonb default '{}') returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (v, p_email, '{"provider": "email", "providers": ["email"]}', p_user);
  update auth.users set raw_app_meta_data = raw_app_meta_data || p_app where id = v;
  return v;
end $$;

do $tests$
declare
  v_admin uuid; v_comp uuid; v_other uuid; v_loc uuid; u uuid; u2 uuid; u3 uuid; s text; n int; r record; v_before text;
begin
  select u0.id into v_admin from auth.users u0 where lower(u0.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  perform pg_temp.ok(v_comp is not null, 'test setup: the admin has a company');
  select id into v_loc from public.work_locations where company_id = v_comp order by name limit 1;
  if v_loc is null then
    insert into public.work_locations (name, company_id) values ('مقر الاختبار', v_comp) returning id into v_loc;
  end if;
  perform pg_temp.ok(v_loc is not null, 'test setup: the company has a work place');

  -- 1) the createUser order: insert without company, then update with company_id -> employee and membership exist
  u := pg_temp.gotrue_create('new.one@example.com', jsonb_build_object('company_id', v_comp, 'company_role', 'employee', 'role', 'employee'),
                             '{"full_name": "موظف جديد للاختبار", "department": "المبيعات"}');
  select e.company_id, e.full_name, e.department into r from public.employees e where e.id = u;
  perform pg_temp.ok(r.company_id = v_comp, 'createUser order: the employee row is created in the company of app_metadata', coalesce(r.company_id::text, 'no row'));
  perform pg_temp.ok(r.full_name = 'موظف جديد للاختبار' and r.department = 'المبيعات', 'createUser order: name and department come from user_metadata');
  perform pg_temp.ok(exists (select 1 from public.company_members m where m.user_id = u and m.company_id = v_comp and m.role = 'employee'),
    'createUser order: the membership is created as employee');

  -- 2) the next step of create-employee: the admin saves the HR profile of the new account
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  set local role authenticated;
  s := pg_temp.err(format($q$select public.admin_save_employee_profile(%L, 'T-9001', 'موظف جديد للاختبار', 'المبيعات', 'محاسب', 'male',
        date '1990-01-01', date '2026-11-01', %L, true, true, 1200, '[]'::jsonb,
        (select jsonb_agg(jsonb_build_object('weekday', g, 'is_workday', false)) from generate_series(0, 6) g), '{}'::jsonb)$q$, u, v_loc));
  reset role;
  perform pg_temp.ok(s = '', 'the admin can save the profile of the new account (was employee_not_found)', s);
  perform pg_temp.ok((select employee_number from public.employees where id = u) = 'T-9001', 'the employee number is the one the admin chose');

  -- 3) the role from app_metadata: a company admin account gets the company_admin membership
  u2 := pg_temp.gotrue_create('new.admin@example.com', jsonb_build_object('company_id', v_comp, 'company_role', 'company_admin'));
  perform pg_temp.ok((select role from public.company_members where user_id = u2) = 'company_admin', 'company_role company_admin -> company_admin membership');

  -- 4) the old order (company_id already in the INSERT) still works exactly as before
  insert into auth.users (id, email, raw_app_meta_data) values (gen_random_uuid(), 'direct@example.com', jsonb_build_object('company_id', v_comp))
  returning id into u3;
  perform pg_temp.ok(exists (select 1 from public.employees where id = u3 and company_id = v_comp), 'company_id at insert: created as before');

  -- 5) no company_id at all (e.g. a platform account): no row, as before
  u3 := pg_temp.gotrue_create('nocompany@example.com', '{"role": "x"}');
  perform pg_temp.ok(not exists (select 1 from public.employees where id = u3), 'no company_id: no employee row (as before)');

  -- 6) an invalid or inactive company in the update: refused like at insert (createUser fails and creates nothing)
  s := pg_temp.err(format('select pg_temp.gotrue_create(%L, %L::jsonb)', 'bad@example.com', jsonb_build_object('company_id', gen_random_uuid())));
  perform pg_temp.ok(s = 'invalid_company', 'unknown company in the update: invalid_company', s);
  s := pg_temp.err(format('select pg_temp.gotrue_create(%L, %L::jsonb)', 'bad2@example.com', '{"company_id": "not-a-uuid"}'));
  perform pg_temp.ok(s = 'invalid_company', 'company_id that is not a uuid: invalid_company', s);

  -- 7) existing accounts: later app_metadata updates change nothing (password change, reset, a role flag), even in an inactive company
  select e.company_id into v_other from public.employees e where e.id <> v_admin and e.id <> u and e.company_id = v_comp limit 1;
  select string_agg(format('%s|%s|%s|%s', e.id, e.company_id, e.employee_number, e.full_name), ',' order by e.id) into v_before from public.employees e;
  update auth.users set raw_app_meta_data = raw_app_meta_data || '{"must_change_password": false}' where id = v_admin;
  update auth.users set raw_app_meta_data = raw_app_meta_data || jsonb_build_object('company_id', gen_random_uuid()) where id = u;
  perform pg_temp.ok((select string_agg(format('%s|%s|%s|%s', e.id, e.company_id, e.employee_number, e.full_name), ',' order by e.id) from public.employees e) = v_before,
    'updates of an existing account never touch employees (even a changed company_id)');
  perform pg_temp.ok((select company_id from public.company_members where user_id = u) = v_comp, 'a changed company_id never moves an existing membership');
  update public.companies set is_active = false where id = v_comp;
  s := pg_temp.err(format($q$update auth.users set raw_app_meta_data = raw_app_meta_data || '{"must_change_password": true}' where id = %L$q$, v_admin));
  perform pg_temp.ok(s = '', 'an existing account of an INACTIVE company can still be updated (no invalid_company)', s);
  update public.companies set is_active = true where id = v_comp;
  -- an update that does not touch app_metadata does not run the function at all
  s := pg_temp.err(format($q$update auth.users set email = email where id = %L$q$, v_admin));
  perform pg_temp.ok(s = '', 'an update of other columns is fine', s);

  -- 8) the trigger and the function keep their safety settings
  select count(*) into n from pg_trigger t where t.tgrelid = 'auth.users'::regclass and t.tgname = 'on_auth_user_created' and not t.tgisinternal;
  perform pg_temp.ok(n = 1, 'one trigger on auth.users, same name');
  perform pg_temp.ok((select prosecdef from pg_proc where oid = 'public.handle_new_auth_user()'::regprocedure), 'the function is still security definer');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.handle_new_auth_user()', 'execute')
                     and not has_function_privilege('authenticated', 'public.handle_new_auth_user()', 'execute'), 'nobody can call the function directly');

  insert into t_res (name, ok) values ('END part 1', true);
end
$tests$;

do $report$
declare v text;
begin
  -- a block that stopped on an error must show as a failure, not as fewer passes
  insert into t_res (name, ok, detail) select 'part ' || blk.k || ' did not finish', false, 'a block stopped on an error' from generate_series(1, 1) blk(k)
  where not exists (select 1 from t_res where t_res.name = 'END part ' || blk.k);
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
