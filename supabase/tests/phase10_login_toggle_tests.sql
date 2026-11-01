-- Phase 10: the employee can turn fingerprint SIGN-IN on or off (the punch fingerprint is a company rule and is not affected).
-- Run with: psql -v admin_email=<company admin email> -f <this file>   (supabase/local/test-db.sh runs it on a fresh copy)
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid, app jsonb default '{}') returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'app_metadata', app)::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; v_comp uuid; r jsonb; s text; n int;
  k_pub text := 'pQECAyYgASFYIGZha2UtcHVibGljLWtleS14LWNvb3JkaW5hdGUtMzJiIlggZmFrZS1wdWJsaWMta2V5LXktY29vcmRpbmF0ZS0zMmI';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) and e.company_id = v_comp order by employee_number limit 1;
  update public.companies set biometric_policy = 'required' where id = v_comp;
  perform public.service_webauthn_register(a, 'cred-a', k_pub, 3, array['internal'], 'iPhone');
  perform public.service_webauthn_register(b, 'cred-b', k_pub, 0, array['internal'], 'Android');

  -- default: on (phones registered before this phase keep working)
  perform pg_temp.as_user(a);
  r := public.employee_webauthn_context();
  perform pg_temp.ok((r ->> 'login_enabled')::boolean is true, 'a registered phone has fingerprint sign-in ON by default', r::text);
  perform pg_temp.ok((public.employee_attendance_state() -> 'biometric' ->> 'login_enabled')::boolean is true, 'the app state tells it (on)');
  reset role;
  r := public.service_login_context('cred-a');
  perform pg_temp.ok(r ->> 'employee_id' = a::text, 'sign-in context works while it is on');

  -- turning it off
  r := public.service_webauthn_set_login(a, false);
  perform pg_temp.ok((r ->> 'login_enabled')::boolean is false, 'set_login(false) answers off', r::text);
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'login_disabled', 'off: sign-in context refused with login_disabled', s);
  s := pg_temp.err(format('select public.service_login_put_challenge(%L, %L)', 'cred-a', 'chal-x'));
  perform pg_temp.ok(s = 'login_disabled', 'off: no sign-in challenge is made either', s);
  perform pg_temp.as_user(a);
  r := public.employee_webauthn_context();
  perform pg_temp.ok((r ->> 'login_enabled')::boolean is false and r -> 'credential' ->> 'credential_id' = 'cred-a' and (r ->> 'has_device')::boolean,
                     'off: the device is still registered (the punch fingerprint keeps working)', r::text);
  perform pg_temp.ok((public.employee_attendance_state() -> 'biometric' ->> 'login_enabled')::boolean is false
                     and (public.employee_attendance_state() -> 'biometric' ->> 'has_device')::boolean, 'the app state tells it (off, device kept)');
  reset role;
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'auth.biometric_login_disabled' and actor_id = a) = 1, 'turning it off is written to the audit log');
  r := public.service_login_context('cred-b');
  perform pg_temp.ok(r ->> 'employee_id' = b::text, 'another employee is not affected');
  r := public.service_webauthn_set_login(a, false);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'auth.biometric_login_disabled' and actor_id = a) = 1, 'turning off twice writes one audit row');

  -- turning it on again (the Edge Function verified the fingerprint first and passes the new signature counter)
  r := public.service_webauthn_set_login(a, true, 5);
  perform pg_temp.ok((r ->> 'login_enabled')::boolean is true, 'set_login(true) answers on', r::text);
  r := public.service_login_context('cred-a');
  perform pg_temp.ok((r -> 'credential' ->> 'sign_count')::int = 5, 'on again: sign-in works and the counter moved to 5', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'auth.biometric_login_enabled' and actor_id = a) = 1, 'turning it on is written to the audit log');
  s := pg_temp.err(format('select public.service_webauthn_set_login(%L, true, 4)', a));
  perform pg_temp.ok(s = 'biometric_failed', 'a counter that does not grow (copied key) cannot turn it on', s);
  perform public.service_webauthn_set_login(a, false);
  s := pg_temp.err(format('select public.service_webauthn_set_login(%L, true, 5)', a));
  perform pg_temp.ok(s = 'biometric_failed' and (select not w.login_enabled from public.webauthn_credentials w where w.employee_id = a), 'a refused enable leaves it off', s);

  -- no phone registered: nothing to switch
  s := pg_temp.err(format('select public.service_webauthn_set_login(%L, false)', c));
  perform pg_temp.ok(s = 'device_not_registered', 'no registered phone: device_not_registered', s);

  -- a removed and re-registered phone starts with sign-in ON again (it is a new device)
  perform pg_temp.as_user(v_admin);
  perform public.admin_remove_device(a);
  reset role;
  perform public.service_webauthn_register(a, 'cred-a2', k_pub, 0, array['internal'], 'new iPhone');
  perform pg_temp.ok((select w.login_enabled from public.webauthn_credentials w where w.employee_id = a), 'a newly registered phone starts with sign-in on');

  -- nobody but the service role
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.service_webauthn_set_login(uuid, boolean, bigint)', 'execute')
    and not has_function_privilege('anon', 'public.service_webauthn_set_login(uuid, boolean, bigint)', 'execute')
    and has_function_privilege('service_role', 'public.service_webauthn_set_login(uuid, boolean, bigint)', 'execute'),
    'only the service role can switch it');
  perform pg_temp.ok(not has_column_privilege('authenticated', 'public.webauthn_credentials', 'login_enabled', 'update'), 'users cannot write the flag directly');
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
