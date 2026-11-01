-- Phase 9: fingerprint login (service-role functions behind the Edge Function). Run with: psql -v admin_email=<company admin email> -f <this file>
-- Each test file runs on a fresh copy (supabase/local/test-db.sh); the last statement always raises.
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
  v_admin uuid; a uuid; b uuid; v_comp uuid; r jsonb; s text; v_ch text; v_id uuid; v_w record; i int; v_n int;
  k_pub text := 'pQECAyYgASFYIGZha2UtcHVibGljLWtleS14LWNvb3JkaW5hdGUtMzJiIlggZmFrZS1wdWJsaWMta2V5LXktY29vcmRpbmF0ZS0zMmI';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;

  -- no device yet
  update public.companies set biometric_policy = 'required' where id = v_comp;
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'device_not_registered', 'unknown credential: device_not_registered', s);

  perform public.service_webauthn_register(a, 'cred-a', k_pub, 3, array['internal'], 'iPhone');
  perform public.service_webauthn_register(b, 'cred-b', k_pub, 0, array['internal'], 'Android');

  -- one phone only (phase 8b rule stays)
  s := pg_temp.err(format('select public.service_webauthn_register(%L, %L, %L, 0, array[%L], %L)', a, 'cred-a2', k_pub, 'internal', 'friend phone'));
  perform pg_temp.ok(s = 'device_already_registered', 'a second phone cannot be registered for the same employee', s);

  -- context
  r := public.service_login_context('cred-a');
  perform pg_temp.ok((r ->> 'employee_id')::uuid = a and r ->> 'email' is not null and r -> 'credential' ->> 'credential_id' = 'cred-a'
                     and (r -> 'credential' ->> 'sign_count')::int = 3 and r -> 'credential' ->> 'public_key_b64u' is not null,
                     'eligible credential: context has the employee, e-mail and the key', r::text);
  perform pg_temp.ok(r ->> 'email' = (select u.email from auth.users u where u.id = a), 'context e-mail is the account e-mail');

  -- ineligible states
  update public.companies set biometric_policy = 'off' where id = v_comp;
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'biometric_off', 'company policy off: biometric_off', s);
  update public.companies set biometric_policy = 'required' where id = v_comp;
  update public.employees set is_active = false where id = a;
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'device_not_registered', 'inactive employee: device_not_registered (nothing revealed)', s);
  update public.employees set is_active = true where id = a;
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"must_change_password": true}' where id = a;
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'password_required', 'temporary password: password_required', s);
  update auth.users set raw_app_meta_data = raw_app_meta_data - 'must_change_password' where id = a;
  r := public.service_login_context('cred-a');
  perform pg_temp.ok(r ->> 'employee_id' = a::text, 'back to normal after the password was changed');

  -- challenges: single use, bound to the credential, expire, at most 3 per credential
  v_id := public.service_login_put_challenge('cred-a', 'chal-1');
  perform pg_temp.ok(v_id is not null, 'put_challenge returns an id');
  perform pg_temp.ok(public.service_login_take_challenge(v_id, 'cred-b') is null, 'a challenge cannot be taken with another credential');
  v_ch := public.service_login_take_challenge(v_id, 'cred-a');
  perform pg_temp.ok(v_ch = 'chal-1', 'the right credential takes it', v_ch);
  perform pg_temp.ok(public.service_login_take_challenge(v_id, 'cred-a') is null, 'a challenge works once');
  perform pg_temp.ok(public.service_login_take_challenge(gen_random_uuid(), 'cred-a') is null, 'unknown challenge id: nothing');
  v_id := public.service_login_put_challenge('cred-a', 'chal-old');
  update private.login_challenges set expires_at = now() - interval '1 second' where challenge_id = v_id;
  perform pg_temp.ok(public.service_login_take_challenge(v_id, 'cred-a') is null, 'expired challenge is refused');
  for i in 1..5 loop perform public.service_login_put_challenge('cred-a', 'c' || i); end loop;
  select count(*) into v_n from private.login_challenges where credential_id = 'cred-a';
  perform pg_temp.ok(v_n = 3, 'at most 3 active challenges per credential', v_n::text);
  s := pg_temp.err(format('select public.service_login_put_challenge(%L, %L)', 'cred-nope', 'x'));
  perform pg_temp.ok(s = 'device_not_registered', 'no challenge for an unknown credential', s);

  -- result: success
  r := public.service_login_result('cred-a', true, 5);
  select * into v_w from public.webauthn_credentials where credential_id = 'cred-a';
  perform pg_temp.ok((r ->> 'ok')::boolean and v_w.sign_count = 5 and v_w.last_used_at is not null, 'success: counter and last use saved', r::text);
  perform pg_temp.ok(exists (select 1 from public.audit_log where action = 'auth.biometric_login' and actor_id = a and company_id = v_comp), 'success is written to the audit log');
  -- counter that does not grow = copied key
  r := public.service_login_result('cred-a', true, 5);
  perform pg_temp.ok(not (r ->> 'ok')::boolean and r ->> 'error' = 'biometric_failed', 'counter not growing: refused', r::text);
  r := public.service_login_result('cred-a', true, 4);
  perform pg_temp.ok(not (r ->> 'ok')::boolean, 'counter going back: refused');
  perform pg_temp.ok((select count(*) from private.login_failures where credential_id = 'cred-a') = 2, 'both refusals count as failures');
  -- a device that keeps no counter (always 0) still signs in
  r := public.service_login_result('cred-b', true, 0);
  perform pg_temp.ok((r ->> 'ok')::boolean, 'device without a counter: allowed', r::text);

  -- lock: 5 failures in 15 minutes
  delete from private.login_failures;
  for i in 1..4 loop perform public.service_login_result('cred-a', false, null); end loop;
  r := public.service_login_context('cred-a');
  perform pg_temp.ok(r ->> 'employee_id' = a::text, '4 failures: not locked yet');
  perform public.service_login_result('cred-a', false, null);
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'too_many_attempts', '5 failures: too_many_attempts', s);
  s := pg_temp.err(format('select public.service_login_put_challenge(%L, %L)', 'cred-a', 'x'));
  perform pg_temp.ok(s = 'too_many_attempts', 'locked: no new challenge', s);
  s := pg_temp.err(format('select public.service_login_result(%L, true, 99)', 'cred-a'));
  perform pg_temp.ok(s = 'too_many_attempts', 'locked: even a good signature is refused', s);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'auth.biometric_login_locked' and actor_id = a) = 1, 'the lock is audited once');
  perform pg_temp.ok(public.service_login_context('cred-b') ->> 'employee_id' = b::text, 'another credential is not affected');
  update private.login_failures set at = now() - interval '16 minutes';
  r := public.service_login_context('cred-a');
  perform pg_temp.ok(r ->> 'employee_id' = a::text, 'lock ends after 15 minutes');
  -- success clears the failures
  perform public.service_login_result('cred-a', false, null);
  perform public.service_login_result('cred-a', true, 9);
  perform pg_temp.ok((select count(*) from private.login_failures where credential_id = 'cred-a') = 0, 'a good sign-in clears the failures');

  -- admin removes the phone: no more fingerprint sign-in, no punch ticket either
  perform pg_temp.as_user(v_admin);
  perform public.admin_remove_device(a);
  s := pg_temp.err(format('select public.service_login_context(%L)', 'cred-a'));
  perform pg_temp.ok(s = 'device_not_registered', 'device removed by the admin: sign-in refused', s);

  -- nobody but the service role may call these
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.service_login_context(text)', 'execute')
    and not has_function_privilege('anon', 'public.service_login_context(text)', 'execute')
    and not has_function_privilege('authenticated', 'public.service_login_put_challenge(text, text)', 'execute')
    and not has_function_privilege('anon', 'public.service_login_take_challenge(uuid, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.service_login_result(text, boolean, bigint)', 'execute')
    and has_function_privilege('service_role', 'public.service_login_context(text)', 'execute'),
    'only the service role can run the login functions');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'private.login_challenges', 'select')
    and not has_table_privilege('anon', 'private.login_failures', 'select'), 'login tables are closed to users');
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
