-- Phase 11: when may an employee ask for leave (back days / notice days, enforced by a trigger).
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

do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; v_tz text; v_today date; r jsonb; s text;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  v_today := (now() at time zone v_tz)::date;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;

  perform pg_temp.ok((select leave_back_days = 0 and leave_notice_days = 0 from public.companies where id = v_comp), 'default: 0 days back, 0 days notice');

  -- default: today or later
  perform pg_temp.as_user(a);
  set local role authenticated;
  r := public.employee_leave_window();
  perform pg_temp.ok((r ->> 'earliest')::date = v_today and (r ->> 'today')::date = v_today, 'employee_leave_window: earliest is today', r::text);
  s := pg_temp.err(format('select public.employee_submit_request(gen_random_uuid(), ''leave'', ''annual'', %L, %L, null, null, ''x'')', v_today - 1, v_today + 5));
  perform pg_temp.ok(s = 'leave_date_not_allowed', 'yesterday is refused', s);
  s := pg_temp.err(format('select public.employee_submit_request(gen_random_uuid(), ''leave'', ''annual'', %L, %L, null, null, ''x'')', v_today - 30, v_today - 24));
  perform pg_temp.ok(s = 'leave_date_not_allowed', 'a month ago is refused (the old 30-day rule is gone)', s);
  reset role;

  -- admin: back 2 days
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_set_leave_window(2, 0);
  perform pg_temp.ok((r ->> 'back_days')::int = 2 and (r ->> 'notice_days')::int = 0, 'admin saves 2 days back', r::text);
  s := pg_temp.err('select public.admin_set_leave_window(1, 1)');
  perform pg_temp.ok(s = 'invalid_settings', 'back and notice together are refused', s);
  s := pg_temp.err('select public.admin_set_leave_window(-1, 0)');
  perform pg_temp.ok(s = 'invalid_settings', 'negative is refused', s);
  s := pg_temp.err('select public.admin_set_leave_window(0, 400)');
  perform pg_temp.ok(s = 'invalid_settings', 'more than 365 is refused', s);
  reset role;
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'company.leave_window') = 1, 'the change is written to the audit log (refused ones are not)');
  perform pg_temp.as_user(a);
  set local role authenticated;
  perform pg_temp.ok((public.employee_leave_window() ->> 'earliest')::date = v_today - 2, 'earliest is now 2 days back');
  s := pg_temp.err(format('select public.employee_submit_request(gen_random_uuid(), ''leave'', ''unpaid'', %L, %L, null, null, ''x'')', v_today - 3, v_today + 3));
  perform pg_temp.ok(s = 'leave_date_not_allowed', '3 days back is refused', s);
  s := pg_temp.err('select public.admin_get_leave_window()');
  perform pg_temp.ok(s <> '', 'an employee cannot read the admin setting', s);
  s := pg_temp.err('select public.admin_set_leave_window(0, 0)');
  perform pg_temp.ok(s <> '', 'an employee cannot change the rule', s);
  reset role;

  -- admin: 2 days notice
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_leave_window(0, 2);
  reset role;
  perform pg_temp.as_user(a);
  set local role authenticated;
  perform pg_temp.ok((public.employee_leave_window() ->> 'earliest')::date = v_today + 2, 'earliest is now today + 2');
  s := pg_temp.err(format('select public.employee_submit_request(gen_random_uuid(), ''leave'', ''unpaid'', %L, %L, null, null, ''x'')', v_today + 1, v_today + 7));
  perform pg_temp.ok(s = 'leave_date_not_allowed', 'tomorrow is refused with 2 days notice', s);
  s := pg_temp.err(format('select public.employee_submit_request(gen_random_uuid(), ''leave'', ''unpaid'', %L, %L, null, null, ''x'')', v_today + 5, v_today + 11));
  perform pg_temp.ok(s = '', 'a day 5 days ahead is accepted', s);
  reset role;
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
