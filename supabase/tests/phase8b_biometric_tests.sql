-- Phase 8b: fingerprint (WebAuthn) tickets. Run with: psql -v admin_email=<company admin email> -f <this file>
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
-- forget A's punches so the next punch is a check-in again
create function pg_temp.reset_punches(u uuid) returns void language sql as $$
  delete from public.attendance_sessions where employee_id = u; delete from public.attendance_events where employee_id = u $$;
create function pg_temp.punch(req uuid, bio text default 'ticket') returns text language plpgsql as $$
begin perform public.employee_punch(req, 'check_in', 'not_requested', null, null, null, bio); return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; r jsonb; s text; v_ev record;
  qa uuid := gen_random_uuid(); qb uuid := gen_random_uuid(); qc uuid := gen_random_uuid(); qd uuid := gen_random_uuid();
  k_pub text := 'pQECAyYgASFYIGZha2UtcHVibGljLWtleS14LWNvb3JkaW5hdGUtMzJiIlggZmFrZS1wdWJsaWMta2V5LXktY29vcmRpbmF0ZS0zMmI';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  update public.employees set location_policy = 'none' where id in (a, b);

  -- policy off: nothing changes
  perform pg_temp.as_user(a);
  s := pg_temp.punch(qa);
  select * into v_ev from public.attendance_events where employee_id = a order by created_at desc limit 1;
  perform pg_temp.ok(s = '' and v_ev.authentication_method = 'password', 'policy off: punch without fingerprint', s);
  perform pg_temp.reset_punches(a);
  s := pg_temp.err(format('select public.employee_punch(p_request_id => %L, p_expected_action => %L, p_reading => %L, p_lat => null, p_lng => null, p_accuracy_m => null)', gen_random_uuid(), 'check_in', 'not_requested'));
  perform pg_temp.ok(s = '', 'old clients (6 named arguments) still work', s);
  perform pg_temp.reset_punches(a);
  r := public.employee_attendance_state();
  perform pg_temp.ok(r -> 'biometric' ->> 'policy' = 'off' and (r -> 'biometric' ->> 'has_device')::boolean = false, 'state shows the policy', (r -> 'biometric')::text);

  -- policy required, no device
  update public.companies set biometric_policy = 'required' where id = v_comp;
  s := pg_temp.punch(gen_random_uuid());
  perform pg_temp.ok(s = 'device_not_registered', 'required + no device: register first', s);
  s := pg_temp.punch(gen_random_uuid(), 'unsupported');
  select * into v_ev from public.attendance_events where employee_id = a order by created_at desc limit 1;
  perform pg_temp.ok(s = '' and v_ev.needs_review and v_ev.metadata ->> 'biometric' = 'unsupported' and v_ev.authentication_method = 'password',
                     'unsupported phone: saved, flagged, marked', coalesce(s, '') || ' ' || coalesce(v_ev.metadata::text, ''));
  perform pg_temp.reset_punches(a);
  s := pg_temp.err(format('select public.employee_punch(%L, %L, %L, null, null, null, %L)', gen_random_uuid(), 'check_in', 'not_requested', 'other'));
  perform pg_temp.ok(s = 'invalid_input', 'unknown p_biometric refused', s);

  -- context for the Edge Function
  r := public.employee_webauthn_context();
  perform pg_temp.ok(r ->> 'policy' = 'required' and (r ->> 'has_device')::boolean = false and (r ->> 'employee_id')::uuid = a
                     and r -> 'credential' = 'null'::jsonb, 'context before registration', r::text);

  -- registration (service role)
  perform set_config('request.jwt.claims', '', true);
  r := public.service_webauthn_register(a, 'cred-a', k_pub, 0, array['internal'], 'iPhone Safari');
  perform pg_temp.ok((select count(*) from public.webauthn_credentials where employee_id = a) = 1, 'device registered');
  perform pg_temp.ok(exists (select 1 from public.audit_log where action = 'device.register' and target_id = a::text), 'registration audited');
  s := pg_temp.err(format('select public.service_webauthn_register(%L, %L, %L, 0, array[%L], %L)', a, 'cred-a2', k_pub, 'internal', 'x'));
  perform pg_temp.ok(s = 'device_already_registered', 'second device refused', s);
  s := pg_temp.err(format('select public.service_webauthn_register(%L, %L, %L, 0, array[%L], %L)', b, 'cred-a', k_pub, 'internal', 'x'));
  perform pg_temp.ok(s <> '', 'same credential id for another employee refused', s);
  s := pg_temp.err(format('select public.service_webauthn_register(%L, %L, %L, 0, null, %L)', b, 'cred-b', k_pub, repeat('x', 300)));
  perform pg_temp.ok(s = '' and (select length(device_label) from public.webauthn_credentials where employee_id = b) = 120, 'long label cut to 120', s);

  -- with a device
  perform pg_temp.as_user(a);
  r := public.employee_webauthn_context();
  perform pg_temp.ok((r ->> 'has_device')::boolean and r -> 'credential' ->> 'credential_id' = 'cred-a'
                     and r -> 'credential' ->> 'public_key_b64u' = k_pub and (r -> 'credential' ->> 'sign_count')::int = 0, 'context after registration', r::text);
  s := pg_temp.punch(gen_random_uuid());
  perform pg_temp.ok(s = 'biometric_required', 'device + no ticket refused', s);
  s := pg_temp.punch(gen_random_uuid(), 'unsupported');
  perform pg_temp.ok(s = 'biometric_required', 'device + "unsupported" refused', s);

  -- tickets
  perform set_config('request.jwt.claims', '', true);
  r := public.service_webauthn_issue_ticket(a, 'cred-a', 1, qa);
  perform pg_temp.as_user(a);
  s := pg_temp.punch(qb);
  perform pg_temp.ok(s = 'biometric_required', 'ticket for another request refused', s);
  s := pg_temp.punch(qa);
  select * into v_ev from public.attendance_events where employee_id = a order by created_at desc limit 1;
  perform pg_temp.ok(s = '' and v_ev.authentication_method = 'biometric' and not v_ev.needs_review, 'ticket accepted, recorded as fingerprint', s);
  r := public.employee_punch(qa, 'check_in', 'not_requested');
  perform pg_temp.ok((r ->> 'duplicate')::boolean, 'retry of a saved punch returns it (no new ticket needed)', r::text);
  perform pg_temp.reset_punches(a);
  s := pg_temp.punch(qa);
  perform pg_temp.ok(s = 'biometric_required', 'used ticket refused', s);
  perform set_config('request.jwt.claims', '', true);
  perform public.service_webauthn_issue_ticket(a, 'cred-a', 2, qc);
  update private.punch_tickets set expires_at = now() - interval '1 second' where employee_id = a and request_id = qc;
  perform pg_temp.as_user(a);
  s := pg_temp.punch(qc);
  perform pg_temp.ok(s = 'biometric_required', 'expired ticket refused', s);
  perform set_config('request.jwt.claims', '', true);
  perform public.service_webauthn_issue_ticket(b, 'cred-b', 0, qd);
  perform pg_temp.as_user(a);
  s := pg_temp.punch(qd);
  perform pg_temp.ok(s = 'biometric_required', 'another employee''s ticket refused', s);

  -- ticket issuing rules
  perform set_config('request.jwt.claims', '', true);
  s := pg_temp.err(format('select public.service_webauthn_issue_ticket(%L, %L, 5, %L)', a, 'cred-b', gen_random_uuid()));
  perform pg_temp.ok(s = 'biometric_failed', 'credential of another employee refused', s);
  s := pg_temp.err(format('select public.service_webauthn_issue_ticket(%L, %L, 2, %L)', a, 'cred-a', gen_random_uuid()));
  perform pg_temp.ok(s = 'biometric_failed', 'sign count not increasing refused', s);
  s := pg_temp.err(format('select public.service_webauthn_issue_ticket(%L, %L, 0, %L)', b, 'cred-b', gen_random_uuid()));
  perform pg_temp.ok(s = '', 'device without a counter (0/0) accepted', s);
  perform pg_temp.ok((select sign_count from public.webauthn_credentials where employee_id = a) = 2
                     and (select last_used_at from public.webauthn_credentials where employee_id = a) is not null, 'count and last use saved');

  -- challenges
  perform public.service_webauthn_put_challenge(a, 'punch', 'abc');
  perform pg_temp.ok(public.service_webauthn_take_challenge(a, 'punch') = 'abc', 'challenge returned once');
  perform pg_temp.ok(public.service_webauthn_take_challenge(a, 'punch') is null, 'then gone');
  perform public.service_webauthn_put_challenge(a, 'register', 'def');
  update private.webauthn_challenges set expires_at = now() - interval '1 second' where employee_id = a;
  perform pg_temp.ok(public.service_webauthn_take_challenge(a, 'register') is null, 'expired challenge ignored');
  s := pg_temp.err(format('select public.service_webauthn_put_challenge(%L, %L, %L)', a, 'other', 'x'));
  perform pg_temp.ok(s <> '', 'unknown purpose refused', s);

  -- privileges
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.service_webauthn_register(uuid, text, text, bigint, text[], text)', 'execute')
    and not has_function_privilege('authenticated', 'public.service_webauthn_issue_ticket(uuid, text, bigint, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.service_webauthn_put_challenge(uuid, text, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.service_webauthn_take_challenge(uuid, text)', 'execute')
    and not has_function_privilege('anon', 'public.service_webauthn_issue_ticket(uuid, text, bigint, uuid)', 'execute'), 'service functions closed to app users');
  perform pg_temp.ok(has_function_privilege('service_role', 'public.service_webauthn_issue_ticket(uuid, text, bigint, uuid)', 'execute'), 'service role can issue tickets');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.webauthn_credentials', 'select')
    and not has_table_privilege('anon', 'public.webauthn_credentials', 'select')
    and not has_table_privilege('authenticated', 'private.punch_tickets', 'insert'), 'no direct table access');

  -- admin
  perform pg_temp.as_user(v_admin);
  r := public.admin_get_employee_profile(a);
  perform pg_temp.ok(r -> 'device' ->> 'device_label' = 'iPhone Safari', 'profile shows the device', (r -> 'device')::text);
  perform pg_temp.ok((select has_device from public.admin_list_employees() where id = a), 'employee list shows has_device');
  s := pg_temp.err(format('select public.admin_remove_device(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'employee_not_found', 'unknown / other company employee refused', s);
  perform pg_temp.as_user(a);
  s := pg_temp.err(format('select public.admin_remove_device(%L)', a));
  perform pg_temp.ok(s = 'forbidden', 'employee cannot remove devices', s);
  perform pg_temp.as_user(v_admin);
  r := public.admin_remove_device(a);
  perform pg_temp.ok(not exists (select 1 from public.webauthn_credentials where employee_id = a)
                     and exists (select 1 from public.audit_log where action = 'device.remove' and target_id = a::text), 'device removed and audited');
  perform pg_temp.ok(public.admin_get_employee_profile(a) -> 'device' = 'null'::jsonb, 'profile: no device');
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
