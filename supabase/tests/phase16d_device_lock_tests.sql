-- Phase 16d: an account works only on the first phone it was opened on, until the admin unbinds that phone.
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
-- claims of a real session (session_id) or of an old-style token (none)
create function pg_temp.as_sess(u uuid, sid uuid, app jsonb default '{}') returns void language sql as $$
  select set_config('request.jwt.claims', (jsonb_build_object('sub', u, 'role', 'authenticated', 'app_metadata', app)
    || case when sid is null then '{}'::jsonb else jsonb_build_object('session_id', sid) end)::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.try_s(u uuid, sid uuid, q text, app jsonb default '{}') returns text language plpgsql as $$
declare s text;
begin
  perform pg_temp.as_sess(u, sid, app);
  set local role authenticated;
  s := pg_temp.err(q);
  reset role;
  return s;
end $$;
create function pg_temp.new_sess(u uuid, at_ timestamptz default now()) returns uuid language sql as
  $$ insert into auth.sessions (user_id, created_at) values (u, at_) returning id $$;
create function pg_temp.bind(u uuid, sid uuid, k text) returns text language sql as
  $$ select pg_temp.try_s(u, sid, format('select public.employee_bind_device(%L, %L)', k, 'Test phone')) $$;
create function pg_temp.state(u uuid, sid uuid) returns text language sql as
  $$ select pg_temp.try_s(u, sid, 'select public.employee_attendance_state()') $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; sb uuid; r text; n int; j jsonb;
  k1 text := repeat('A', 43); k2 text := repeat('B', 43);
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  perform pg_temp.ok((select bool_and(not device_lock) from public.companies), 'existing companies start with the lock off');
  update public.companies set device_lock = true where id = v_comp;
  s1 := pg_temp.new_sess(a, now() - interval '1 hour');

  -- ---------------------------------------------------------------- before binding
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.employee_bind_device(text, text)', 'execute')
                     and not has_function_privilege('anon', 'public.employee_bind_device(text, text)', 'execute'), 'only signed-in users can bind');
  r := pg_temp.state(a, s1);
  perform pg_temp.ok(r = 'device_not_bound', 'a real session that is not bound is refused', r);
  r := pg_temp.try_s(a, s1, 'select public.employee_punch(gen_random_uuid(), ''check_in'', ''not_requested'')');
  perform pg_temp.ok(r = 'device_not_bound', 'punch refused too', r);
  r := pg_temp.state(a, null);
  perform pg_temp.ok(r = '', 'a token without session_id (old style) is not affected', r);

  -- ---------------------------------------------------------------- first phone
  r := pg_temp.bind(a, s1, 'short');
  perform pg_temp.ok(r = 'invalid_input', 'a bad key is refused', r);
  r := pg_temp.try_s(a, s1, format('select public.employee_bind_device(%L)', k1), '{"must_change_password": true}');
  perform pg_temp.ok(r = 'must_change_password', 'temporary password: no binding yet', r);
  r := pg_temp.bind(a, s1, k1);
  perform pg_temp.ok(r = '', 'first phone binds', r);
  perform pg_temp.ok((select count(*) from public.employee_devices where employee_id = a and key_hash <> k1) = 1, 'only the hash is stored');
  perform pg_temp.ok(pg_temp.state(a, s1) = '', 'the bound session works');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'device.bound' and target_id = a::text) = 1, 'audit: device.bound');

  s2 := pg_temp.new_sess(a);
  perform pg_temp.ok(pg_temp.state(a, s2) = 'device_not_bound', 'a new session (sign-in again) must be bound too');
  perform pg_temp.ok(pg_temp.bind(a, s2, k1) = '' and pg_temp.state(a, s2) = '', 'same phone, new sign-in: binds again at once');

  -- ---------------------------------------------------------------- another phone
  s3 := pg_temp.new_sess(a);
  r := pg_temp.bind(a, s3, k2);
  perform pg_temp.ok(r = 'device_locked', 'another phone is refused', r);
  perform pg_temp.ok(pg_temp.state(a, s3) = 'device_not_bound', '... and can do nothing');
  r := pg_temp.try_s(a, s3, 'select public.employee_webauthn_context()');
  perform pg_temp.ok(r = 'device_not_bound', '... not even the fingerprint setup', r);
  r := pg_temp.try_s(a, s3, 'select public.employee_profile_summary()');
  perform pg_temp.ok(r = 'device_not_bound', '... nor his data', r);
  -- someone else's session id cannot be borrowed
  sb := pg_temp.new_sess(b);
  perform pg_temp.ok(pg_temp.bind(b, sb, k2) = '', 'B binds his own phone');
  perform pg_temp.ok(pg_temp.state(a, sb) = 'device_not_bound', 'A cannot use B''s bound session id');

  -- ---------------------------------------------------------------- the admin unbinds
  r := pg_temp.try_s(a, s1, format('select public.admin_remove_device(%L)', a));
  perform pg_temp.ok(r <> '', 'an employee cannot unbind', r);
  perform pg_temp.as_sess(v_admin, null);
  j := public.admin_remove_device(a);
  perform pg_temp.ok(not exists (select 1 from public.employee_devices where employee_id = a), 'unbind removes the binding');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'device.unbound' and target_id = a::text) = 1, 'audit: device.unbound');
  perform pg_temp.ok(pg_temp.state(a, s1) = 'device_not_bound', 'the old phone stops at once');
  r := pg_temp.bind(a, s1, k1);
  perform pg_temp.ok(r = 'login_again', 'the old phone cannot take it back with its old session', r);
  s4 := pg_temp.new_sess(a, clock_timestamp() + interval '1 second');
  perform pg_temp.ok(pg_temp.bind(a, s4, k2) = '' and pg_temp.state(a, s4) = '', 'after a new sign-in, the new phone binds');
  s5 := pg_temp.new_sess(a, clock_timestamp() + interval '2 seconds');
  perform pg_temp.ok(pg_temp.bind(a, s5, k1) = 'device_locked', 'now the old phone is the "other phone"');

  -- ---------------------------------------------------------------- the admin sees bindings
  perform pg_temp.as_sess(v_admin, null);
  select count(*) into n from public.admin_list_device_bindings() where employee_id in (a, b);
  perform pg_temp.ok(n = 2, 'admin lists the bound phones', n::text);
  r := pg_temp.try_s(a, s4, 'select count(*) from public.admin_list_device_bindings()');
  perform pg_temp.ok(r <> '', 'employees cannot list bindings', r);

  -- ---------------------------------------------------------------- emergency switch
  update public.companies set device_lock = false where id = v_comp;
  s3 := pg_temp.new_sess(a);
  perform pg_temp.ok(pg_temp.state(a, s3) = '', 'lock switched off: any session works');
  perform pg_temp.ok(pg_temp.bind(a, s3, k1) = '', 'lock switched off: binding never refuses');
  update public.companies set device_lock = true where id = v_comp;
  perform pg_temp.ok(pg_temp.state(a, s3) = 'device_not_bound', 'switched on again: enforced');

  -- the binding table is not readable directly
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.employee_devices', 'select')
                     and not has_table_privilege('anon', 'public.employee_devices', 'select'), 'employee_devices closed to direct reads');
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
