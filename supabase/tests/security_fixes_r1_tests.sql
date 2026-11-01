-- Security audit R1 fixes. Runs inside one transaction and always ends with an exception, so nothing is kept.
-- Run with: psql -v admin_email=<company admin's email> -f security_fixes_r1_tests.sql
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
  v_admin uuid; a uuid; r jsonb; s text; k_p256dh text := repeat('B', 87); k_auth text := repeat('a', 22);
  v_ev uuid; v_row record;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id =
    (select company_id from public.employees where id = v_admin) order by employee_number limit 1;
  update public.employees set location_policy = 'record' where id = a;

  -- SEC-001 / SEC-002: the offline and legacy punch functions cannot be called by app users
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.employee_punch_offline(uuid, text, text, double precision, double precision, double precision, text, timestamp with time zone, timestamp with time zone, bigint, timestamp with time zone)', 'execute'), 'offline punch closed to employees');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.record_attendance(public.attendance_event_type, double precision, double precision, numeric, text, text, uuid, timestamp with time zone)', 'execute'), 'legacy record_attendance closed to employees');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.employee_punch_offline(uuid, text, text, double precision, double precision, double precision, text, timestamp with time zone, timestamp with time zone, bigint, timestamp with time zone)', 'execute'), 'offline punch closed to anon');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.employee_punch(uuid, text, text, double precision, double precision, double precision, text)', 'execute'), 'normal punch still open');

  -- SEC-003: normal reading is not flagged
  perform pg_temp.as_user(a);
  r := public.employee_punch(gen_random_uuid(), 'check_in', 'ok', 32.8872345, 13.1913456, 14.6);
  perform pg_temp.ok((r ->> 'needs_review')::boolean = false, 'ordinary reading not flagged', r::text);
  v_ev := (r ->> 'event_id')::uuid;
  update public.attendance_events set occurred_at = occurred_at - interval '2 hours' where id = v_ev;

  -- the exact same point again -> flagged as same_point
  r := public.employee_punch(gen_random_uuid(), 'check_out', 'ok', 32.8872345, 13.1913456, 14.6);
  perform pg_temp.ok((r ->> 'needs_review')::boolean, 'identical point flagged', r::text);
  perform pg_temp.ok((select metadata -> 'suspect' from public.attendance_events where id = (r ->> 'event_id')::uuid) = '["same_point"]', 'reason: same_point');
  update public.attendance_events set occurred_at = occurred_at - interval '1 hour' where id = (r ->> 'event_id')::uuid;

  -- accuracy under 3 m -> flagged as perfect_accuracy
  r := public.employee_punch(gen_random_uuid(), 'check_in', 'ok', 32.8890001, 13.1890002, 1);
  perform pg_temp.ok((r ->> 'needs_review')::boolean, 'perfect accuracy flagged', r::text);
  perform pg_temp.ok((select metadata -> 'suspect' from public.attendance_events where id = (r ->> 'event_id')::uuid) = '["perfect_accuracy"]', 'reason: perfect_accuracy');
  v_ev := (r ->> 'event_id')::uuid;

  -- the admin sees the flags
  perform pg_temp.as_user(v_admin);
  select * into v_row from public.admin_list_attendance(null, null, a, null, 10, 0) where event_id = v_ev;
  perform pg_temp.ok(v_row.needs_review and v_row.suspect = array['perfect_accuracy'] and v_row.location_status = 'recorded'
                     and v_row.source = 'pwa' and v_row.offline = false, 'admin list shows review flag, reason, status, source', row_to_json(v_row)::text);

  -- SEC-004: only push-service endpoints
  perform pg_temp.as_user(a);
  s := pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://evil.example.com/push/1', k_p256dh, k_auth));
  perform pg_temp.ok(s = 'invalid_input', 'unknown host refused', s);
  s := pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://fcm.googleapis.com.evil.com/x', k_p256dh, k_auth));
  perform pg_temp.ok(s = 'invalid_input', 'look-alike host refused', s);
  s := pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://fcm.googleapis.com@evil.com/x', k_p256dh, k_auth));
  perform pg_temp.ok(s = 'invalid_input', 'user-info trick refused', s);
  s := pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://fcm.googleapis.com:8443/x', k_p256dh, k_auth));
  perform pg_temp.ok(s = 'invalid_input', 'other port refused', s);
  s := pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'http://fcm.googleapis.com/fcm/send/x', k_p256dh, k_auth));
  perform pg_temp.ok(s = 'invalid_input', 'plain http refused', s);
  s := pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://web.push.apple.com/QOx', k_p256dh, k_auth))
    || pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://api.push.apple.com/3/device/x', k_p256dh, k_auth))
    || pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://wns2-par02p.notify.windows.com/w/?token=x', k_p256dh, k_auth))
    || pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://updates.push.services.mozilla.com/wpush/v2/x', k_p256dh, k_auth))
    || pg_temp.err(format('select public.employee_save_push_subscription(%L, %L, %L)', 'https://fcm.googleapis.com/fcm/send/x', k_p256dh, k_auth));
  perform pg_temp.ok(s = '', 'Apple, Windows, Mozilla and FCM accepted', s);

  -- SEC-006: an admin with a temporary password is stopped until it is changed
  perform pg_temp.as_user(v_admin, '{"must_change_password": true}');
  s := pg_temp.err('select count(*) from public.admin_list_employees()');
  perform pg_temp.ok(s = 'must_change_password', 'admin functions refused with a temporary password', s);
  s := pg_temp.err('select public.admin_get_company_settings()');
  perform pg_temp.ok(s = 'must_change_password', 'settings refused with a temporary password', s);
  perform pg_temp.as_user(v_admin, '{"must_change_password": false}');
  s := pg_temp.err('select count(*) from public.admin_list_employees()');
  perform pg_temp.ok(s = '', 'admin functions work after the change', s);
  perform pg_temp.as_user(a);
  s := pg_temp.err('select count(*) from public.admin_list_employees()');
  perform pg_temp.ok(s = 'forbidden', 'employees still refused', s);
  insert into public.platform_admins (user_id) values (v_admin) on conflict do nothing;
  perform pg_temp.as_user(v_admin, '{"must_change_password": true}');
  s := pg_temp.err('select count(*) from public.platform_list_companies()');
  perform pg_temp.ok(s = 'forbidden', 'platform functions refused with a temporary password', s);
  perform pg_temp.as_user(v_admin);
  s := pg_temp.err('select count(*) from public.platform_list_companies()');
  perform pg_temp.ok(s = '', 'platform functions work without the flag', s);

  -- SEC-007: grants
  perform pg_temp.ok(not has_table_privilege('anon', 'public.employees', 'select')
    and not has_table_privilege('anon', 'public.attendance_events', 'insert')
    and not has_table_privilege('anon', 'public.employee_geofences', 'delete')
    and not has_table_privilege('anon', 'public.attendance_sessions', 'update'), 'anon has no table access');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.employees', 'update')
    and not has_table_privilege('authenticated', 'public.employees', 'insert')
    and not has_table_privilege('authenticated', 'public.employee_geofences', 'delete')
    and not has_table_privilege('authenticated', 'public.attendance_events', 'insert'), 'authenticated cannot write the tables');
  perform pg_temp.ok(has_table_privilege('authenticated', 'public.attendance_events', 'select'), 'own-row reading (RLS) still possible');

  -- the normal punch still works under the authenticated role after the grant changes
  update public.attendance_events set occurred_at = occurred_at - interval '30 minutes' where id = v_ev;
  perform pg_temp.as_user(a);
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err(format('select public.employee_punch(%L, %L, %L, 32.81, 13.11, 20)', gen_random_uuid(), 'check_out', 'ok'));
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'punch works under the authenticated role', s);
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
