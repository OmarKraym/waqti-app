-- Runs inside one transaction and always ends with an exception, so nothing is kept.
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.at(d date, t text) returns timestamptz language sql as
  $$ select (d + t::time) at time zone 'Africa/Tripoli' $$;
create function pg_temp.box(u uuid, k text) returns bigint language sql as
  $$ select count(*) from public.notifications where user_id = u and kind = k $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; d uuid; v_comp uuid; r jsonb; s text; n int; v_req uuid; v_ap uuid;
  v_today date := (now() at time zone 'Africa/Tripoli')::date;
  v_day date; v_ev uuid;
  k_p256dh text := 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM';
  k_auth text := 'tBHItJI5svbpez7KI4CCXg';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = 'omarkraym5@gmail.com';
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) order by employee_number offset 1 limit 1;
  select id into d from public.employees e where e.is_active and e.id not in (v_admin, a, b) order by employee_number offset 2 limit 1;
  delete from public.approval_steps;   -- default paths
  delete from public.notifications;
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_employee_manager(a, b);

  -- ------------------------------------------------ devices
  perform pg_temp.as_user(a);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-a', k_p256dh, k_auth, 'test');
  perform pg_temp.ok((select count(*) from public.push_subscriptions where user_id = a) = 1, 'employee saves his device');
  s := pg_temp.err(format($q$select public.employee_save_push_subscription('http://evil/x', %L, %L)$q$, k_p256dh, k_auth));
  perform pg_temp.ok(s = 'invalid_input', 'non-https endpoint refused', s);
  perform pg_temp.as_user(b);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-b', k_p256dh, k_auth);
  perform pg_temp.as_user(v_admin);
  perform public.employee_save_push_subscription('https://updates.push.services.mozilla.com/wpush/v2/dev-admin', k_p256dh, k_auth);
  -- the same phone, now signed in as D
  perform pg_temp.as_user(d);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-b', k_p256dh, k_auth);
  perform pg_temp.ok((select user_id from public.push_subscriptions where endpoint like '%dev-b') = d, 'a device signed in by another account moves to him');
  perform public.employee_delete_push_subscription('https://fcm.googleapis.com/fcm/send/dev-b');
  perform pg_temp.as_user(b);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-b', k_p256dh, k_auth);

  -- ------------------------------------------------ settings
  perform pg_temp.as_user(a);
  r := public.employee_get_notification_settings();
  perform pg_temp.ok(r ->> 'remind_check_in' = 'false' and (r ->> 'devices')::int = 1, 'reminders are off by default; 1 device', r::text);
  r := public.employee_set_notification_settings(true, 10, true, 0);
  perform pg_temp.ok((r ->> 'remind_check_in')::boolean and (r ->> 'check_in_before')::int = 10, 'employee turns reminders on', r::text);
  s := pg_temp.err('select public.employee_set_notification_settings(true, 500, false, 0)');
  perform pg_temp.ok(s = 'invalid_input', 'more than 120 minutes refused', s);

  -- ------------------------------------------------ requests: step by step
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_today + 20, v_today + 22);
  v_req := (r ->> 'id')::uuid;
  perform pg_temp.ok(pg_temp.box(b, 'approval_needed') = 1 and pg_temp.box(v_admin, 'approval_needed') = 0 and pg_temp.box(a, 'approval_needed') = 0,
    'submit: only the direct manager is notified');
  r := (select to_jsonb(x) from public.notifications x where user_id = b);
  perform pg_temp.ok(r ->> 'title' = 'طلب بانتظار موافقتك' and r ->> 'body' like '%: إجازة بدون راتب · %' and r ->> 'url' = '?tab=requests',
    'manager notification text', r ->> 'body');
  perform pg_temp.as_user(b);
  v_ap := (select (x ->> 'approval_id')::uuid from jsonb_array_elements(public.approver_inbox()) x where x ->> 'id' = v_req::text);
  perform public.approver_decide(v_ap, 'approve');
  perform pg_temp.ok(pg_temp.box(v_admin, 'approval_needed') = 1 and pg_temp.box(a, 'request_decided') = 0,
    'manager approves: HR (company admin) is notified next; the requester not yet');
  perform pg_temp.as_user(v_admin);
  perform public.admin_decide_request(v_req, 'approve');
  perform pg_temp.ok(pg_temp.box(a, 'request_decided') = 1
    and (select title from public.notifications where user_id = a and kind = 'request_decided') = 'تمت الموافقة على طلبك',
    'final approval: the requester is notified');

  -- rejection carries the note
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'other', null, v_today + 30, v_today + 30, null, null, 'شهادة راتب');
  perform pg_temp.as_user(b);
  v_ap := (select (x ->> 'approval_id')::uuid from jsonb_array_elements(public.approver_inbox()) x where x ->> 'id' = r ->> 'id');
  perform public.approver_decide(v_ap, 'reject', 'غير ممكن الآن');
  perform pg_temp.ok((select body from public.notifications where user_id = a and kind = 'request_decided' and title = 'رُفض طلبك') like '%السبب: غير ممكن الآن',
    'rejection: the requester gets the reason');
  perform pg_temp.ok(pg_temp.box(v_admin, 'approval_needed') = 1, 'rejected by the manager: HR is never notified');

  -- the company admin's own request: he is never notified about it
  delete from public.notifications;
  perform pg_temp.as_user(v_admin);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_today + 40, v_today + 40);
  perform pg_temp.ok(pg_temp.box(v_admin, 'approval_needed') = 0, 'nobody is notified to decide his own request');

  -- permission summary
  delete from public.notifications;
  perform pg_temp.as_user(a);
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time)
  select a, x, true, '08:00', '16:00' from generate_series(0, 6) x;
  r := public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, pg_temp.at(v_today + 2, '10:00'), pg_temp.at(v_today + 2, '11:30'),
         null, false, (select id from public.permission_types where company_id = v_comp and name = 'خروج أثناء الدوام'));
  perform pg_temp.ok((select body from public.notifications where user_id = b) like '%إذن: خروج أثناء الدوام · ' || to_char(v_today + 2, 'DD/MM') || ' 10:00–11:30',
    'permission notification shows type, day and hours', (select body from public.notifications where user_id = b));

  -- ------------------------------------------------ reminders (A: 08:00-16:00 every day, check-in 10 min before, check-out at the end)
  delete from public.notifications;
  v_day := v_today + 5;
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '07:45'));
  perform pg_temp.ok(n = 0, 'check-in reminder: not before its time (07:50)', n::text);
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '07:51'));
  perform pg_temp.ok(n = 1 and pg_temp.box(a, 'reminder_check_in') = 1
    and (select body from public.notifications where user_id = a) like 'يبدأ دوامك الساعة 08:00%', 'check-in reminder at 07:51', n::text);
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '07:55'));
  perform pg_temp.ok(n = 0, 'sent once per day');
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '16:01'));
  perform pg_temp.ok(n = 0, 'check-out reminder: not sent when he never checked in');

  v_day := v_today + 6;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence) values (a, 'check_in', pg_temp.at(v_day, '07:40'), true)
  returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status) values (a, v_day, v_ev, 'open');
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '07:52'));
  perform pg_temp.ok(n = 0, 'check-in reminder: not sent when already checked in');
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '16:03'));
  perform pg_temp.ok(n = 1 and pg_temp.box(a, 'reminder_check_out') = 1
    and (select body from public.notifications where user_id = a and kind = 'reminder_check_out') like 'انتهى دوامك الآن (16:00)%', 'check-out reminder when checked in', n::text);
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '16:20'));
  perform pg_temp.ok(n = 0, 'too late (over 15 min) or already sent: nothing more');
  delete from public.attendance_sessions where employee_id = a;
  delete from public.attendance_events where id = v_ev;

  v_day := v_today + 20;   -- inside A's approved unpaid leave (days +20..+22)
  n := private.enqueue_due_reminders(pg_temp.at(v_day, '07:51'));
  perform pg_temp.ok(n = 0, 'no check-in reminder on an approved leave day');

  update public.employee_work_schedules set is_workday = false, start_time = null, end_time = null where employee_id = a and weekday = extract(dow from v_today + 8)::int;
  n := private.enqueue_due_reminders(pg_temp.at(v_today + 8, '07:51'));
  perform pg_temp.ok(n = 0, 'no reminder on his day off');

  delete from public.push_subscriptions where user_id = a;
  n := private.enqueue_due_reminders(pg_temp.at(v_today + 9, '07:51'));
  perform pg_temp.ok(n = 0, 'no reminder without a device');
  perform pg_temp.as_user(a);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-a', k_p256dh, k_auth, 'test');

  -- ------------------------------------------------ test notification
  delete from public.notifications;
  perform public.employee_test_notification();
  perform pg_temp.ok(pg_temp.box(a, 'test') = 1, 'test notification queued');
  s := pg_temp.err('select public.employee_test_notification()');
  perform pg_temp.ok(s = 'rate_limited', 'second test within 30 s refused', s);
  perform pg_temp.as_user(d);
  s := pg_temp.err('select public.employee_test_notification()');
  perform pg_temp.ok(s = 'no_device', 'test without a device: no_device', s);

  -- ------------------------------------------------ sender: claim, report, dead devices
  perform set_config('role', 'none', true);
  delete from public.notifications;
  perform private.notify(a, v_comp, 'test', 't1', 'b1');
  perform private.notify(d, v_comp, 'test', 't2', 'b2');           -- D has no device
  perform private.notify(b, v_comp, 'test', 'old', 'b3', './', null, 60);
  update public.notifications set created_at = now() - interval '5 minutes' where title = 'old';   -- expired (ttl 60 s)
  r := public.push_claim_batch(10);
  perform pg_temp.ok(jsonb_array_length(r) = 2 and (select count(*) from jsonb_array_elements(r) x where x ->> 'title' = 'old') = 0,
    'claim: 2 to send, the expired one is skipped', r::text);
  perform pg_temp.ok((select jsonb_array_length(x -> 'subscriptions') from jsonb_array_elements(r) x where x ->> 'title' = 't1') = 1
    and (select (x ->> 'ttl')::int between 60 and 86400 from jsonb_array_elements(r) x where x ->> 'title' = 't1'), 'claim carries the devices and the remaining ttl');
  perform pg_temp.ok(jsonb_array_length(public.push_claim_batch(10)) = 0, 'claimed rows are not handed out twice');
  perform public.push_report(jsonb_build_array(
    jsonb_build_object('id', (select id from public.notifications where title = 't1'), 'ok', true, 'gone', jsonb_build_array('https://fcm.googleapis.com/fcm/send/dev-a'), 'delivered', '[]'::jsonb),
    jsonb_build_object('id', (select id from public.notifications where title = 't2'), 'ok', false, 'error', 'boom')));
  perform pg_temp.ok((select sent_at is not null from public.notifications where title = 't1')
    and not exists (select 1 from public.push_subscriptions where endpoint like '%dev-a'), 'report: sent marked, dead device removed');
  update public.notifications set claimed_at = now() - interval '3 minutes' where title = 't2';
  r := public.push_claim_batch(10);
  perform pg_temp.ok(jsonb_array_length(r) = 1 and r -> 0 ->> 'title' = 't2'
    and (select attempts from public.notifications where title = 't2') = 2, 'a failed one is retried after its claim expires', r::text);
  update public.notifications set attempts = 5, claimed_at = null where title = 't2';
  perform pg_temp.ok(jsonb_array_length(public.push_claim_batch(10)) = 0, 'no more than 5 attempts');

  -- ------------------------------------------------ access
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.push_claim_batch(integer)', 'execute')
    and not has_function_privilege('anon', 'public.push_report(jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.push_claim_batch(integer)', 'execute'), 'only the sender (service role) can claim/report');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.push_subscriptions', 'select')
    and not has_table_privilege('authenticated', 'public.notifications', 'select'), 'no direct table access');
  perform pg_temp.as_user(b);
  perform set_config('role', 'authenticated', true);
  s := pg_temp.err('select public.employee_get_notification_settings()')
    || pg_temp.err('select public.employee_set_notification_settings(false, 5, true, 10)');
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'employee calls work under the authenticated role', s);
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
