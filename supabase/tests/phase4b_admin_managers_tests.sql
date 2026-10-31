-- Runs inside one transaction and always ends with an exception, so nothing is kept.
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare v_admin uuid; a uuid; b uuid; r jsonb; s text;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = 'omarkraym5@gmail.com';
  select id into a from public.employees where is_active and id <> v_admin order by employee_number limit 1;
  select id into b from public.employees where is_active and id not in (v_admin, a) order by employee_number limit 1;

  perform pg_temp.as_user(v_admin);
  perform set_config('role', 'authenticated', true);
  r := public.admin_list_employee_managers();
  perform set_config('role', 'none', true);
  perform pg_temp.ok(jsonb_typeof(r) = 'object', 'admin gets an object (works under the authenticated role)', r::text);

  perform public.admin_set_employee_manager(a, b);
  r := public.admin_list_employee_managers();
  perform pg_temp.ok(r ->> a::text = b::text, 'shows the manager just set', r::text);
  perform pg_temp.ok(not (r ? b::text), 'employees without a manager are not listed');

  perform pg_temp.as_user(a);
  s := pg_temp.err('select public.admin_list_employee_managers()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot read it', s);
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_employee_managers()', 'execute'), 'anonymous cannot call it');
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
