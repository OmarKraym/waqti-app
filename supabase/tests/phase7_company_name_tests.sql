-- Runs inside one transaction and always ends with an exception, so nothing is kept.
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; r jsonb; s text; v_old text; n_audit int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin order by employee_number limit 1;
  select name into v_old from public.companies where id = v_comp;
  perform pg_temp.as_user(v_admin);

  r := public.admin_set_company_name('  شركة الاختبار للتجارة  ');
  perform pg_temp.ok(r ->> 'name' = 'شركة الاختبار للتجارة', 'admin renames, spaces trimmed', r::text);
  perform pg_temp.ok((select name from public.companies where id = v_comp) = 'شركة الاختبار للتجارة', 'stored in companies.name');
  perform pg_temp.ok((public.admin_get_company_settings() ->> 'name') = 'شركة الاختبار للتجارة', 'admin settings show the new name');
  perform pg_temp.ok((public.my_admin_context() ->> 'company_name') = 'شركة الاختبار للتجارة', 'admin context shows the new name');
  perform pg_temp.ok(exists (select 1 from public.audit_log where company_id = v_comp and action = 'company.rename'
                              and details ->> 'old_name' = v_old and details ->> 'new_name' = 'شركة الاختبار للتجارة'), 'audited with old and new name');

  -- the employee app shows it
  perform pg_temp.as_user(a);
  perform pg_temp.ok((public.employee_attendance_state() -> 'company' ->> 'name') = 'شركة الاختبار للتجارة', 'employee app shows the new name');

  -- an employee cannot rename
  s := pg_temp.err($q$select public.admin_set_company_name('شركة أخرى')$q$);
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot rename', s);
  perform pg_temp.ok((select name from public.companies where id = v_comp) = 'شركة الاختبار للتجارة', 'name unchanged after refusal');

  -- validation
  perform pg_temp.as_user(v_admin);
  s := pg_temp.err($q$select public.admin_set_company_name('  ')$q$);
  perform pg_temp.ok(s = 'invalid_company_name', 'empty refused', s);
  s := pg_temp.err($q$select public.admin_set_company_name('ش')$q$);
  perform pg_temp.ok(s = 'invalid_company_name', 'one letter refused', s);
  s := pg_temp.err($q$select public.admin_set_company_name(null)$q$);
  perform pg_temp.ok(s = 'invalid_company_name', 'null refused', s);
  s := pg_temp.err(format('select public.admin_set_company_name(%L)', repeat('س', 151)));
  perform pg_temp.ok(s = 'invalid_company_name', 'more than 150 refused', s);
  s := pg_temp.err(format('select public.admin_set_company_name(%L)', E'شركة\nسطر ثان'));
  perform pg_temp.ok(s = 'invalid_company_name', 'two lines refused', s);
  r := public.admin_set_company_name(repeat('س', 150));
  perform pg_temp.ok(length(r ->> 'name') = 150, '150 accepted');

  -- same name again: no new audit row
  select count(*) into n_audit from public.audit_log where company_id = v_comp and action = 'company.rename';
  perform public.admin_set_company_name(repeat('س', 150));
  perform pg_temp.ok((select count(*) from public.audit_log where company_id = v_comp and action = 'company.rename') = n_audit, 'same name: no audit row');

  -- other companies untouched
  perform pg_temp.ok(not exists (select 1 from public.companies where id <> v_comp and name = repeat('س', 150)), 'only my company changed');

  -- grants
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err($q$select public.admin_set_company_name('شركة وقتي')$q$);
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'works under the authenticated role', s);
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_set_company_name(text)', 'execute'), 'anon cannot call it');
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
