-- Phase 16b: punch reminders are ON by default (5 minutes before the shift, and at its end), for every employee.
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
  v_admin uuid; a uuid; b uuid; v_new uuid; v_comp uuid; r jsonb; n int; s text;
  v_day date; v_start timestamptz;
  k_p256dh text := 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM';
  k_auth text := 'tBHItJI5svbpez7KI4CCXg';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) order by employee_number limit 1;

  -- ------------------------------------------------ everyone already there
  select count(*) into n from public.employees e
   where not exists (select 1 from public.notification_settings s where s.employee_id = e.id);
  perform pg_temp.ok(n = 0, 'every employee has reminder settings', n::text);
  select count(*) into n from public.notification_settings
   where not (remind_check_in and check_in_before = 5 and remind_check_out and check_out_before = 0);
  perform pg_temp.ok(n = 0, 'every employee: check-in 5 minutes before, check-out at the end', n::text);

  perform pg_temp.as_user(a);
  r := public.employee_get_notification_settings();
  perform pg_temp.ok(r ->> 'remind_check_in' = 'true' and (r ->> 'check_in_before')::int = 5
                     and r ->> 'remind_check_out' = 'true' and (r ->> 'check_out_before')::int = 0,
                     'the employee sees reminders on (5 / at the end)', r::text);

  -- ------------------------------------------------ a new employee
  insert into auth.users (email, raw_app_meta_data, raw_user_meta_data)
  values ('new16b@example.com', jsonb_build_object('company_id', v_comp), '{"full_name":"موظف جديد"}')
  returning id into v_new;
  select count(*) into n from public.notification_settings
   where employee_id = v_new and remind_check_in and check_in_before = 5 and remind_check_out and check_out_before = 0
     and company_id = v_comp;
  perform pg_temp.ok(n = 1, 'a new employee gets reminders on at once', n::text);

  -- with no row at all (e.g. removed by hand) the getter still says "on"
  delete from public.notification_settings where employee_id = v_new;
  perform pg_temp.as_user(v_new);
  r := public.employee_get_notification_settings();
  perform pg_temp.ok(r ->> 'remind_check_in' = 'true' and (r ->> 'check_in_before')::int = 5 and r ->> 'remind_check_out' = 'true',
                     'no row: the getter shows the new default', r::text);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-new16b', k_p256dh, k_auth, 'test');
  select count(*) into n from public.notification_settings where employee_id = v_new and remind_check_in and check_in_before = 5;
  perform pg_temp.ok(n = 1, 'saving a device creates the row with the new default', n::text);

  -- ------------------------------------------------ the employee's own choice still wins
  perform pg_temp.as_user(b);
  r := public.employee_set_notification_settings(false, 5, false, 0);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-b16b', k_p256dh, k_auth, 'test');
  select count(*) into n from public.notification_settings where employee_id = b and not remind_check_in and not remind_check_out;
  perform pg_temp.ok(n = 1, 'turned off by the employee: saving a device does not turn it back on', n::text);

  -- ------------------------------------------------ the reminder goes out 5 minutes before the shift
  perform pg_temp.as_user(a);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/dev-a16b', k_p256dh, k_auth, 'test');
  delete from public.reminder_log;
  delete from public.notifications;
  delete from public.attendance_sessions where employee_id = a;
  delete from public.attendance_events where employee_id = a;
  v_day := (now() at time zone 'Africa/Tripoli')::date + 1;
  loop  -- the next work day of A
    select shift_start into v_start from private.shift_bounds(a, v_day, 'Africa/Tripoli');
    exit when v_start is not null;
    v_day := v_day + 1;
  end loop;
  perform set_config('role', 'none', true);
  perform private.enqueue_due_reminders(v_start - interval '6 minutes');
  select count(*) into n from public.notifications where user_id = a and kind = 'reminder_check_in';
  perform pg_temp.ok(n = 0, 'no reminder 6 minutes before the shift', n::text);
  perform private.enqueue_due_reminders(v_start - interval '5 minutes');
  select count(*) into n from public.notifications where user_id = a and kind = 'reminder_check_in';
  perform pg_temp.ok(n = 1, 'reminder exactly 5 minutes before the shift', n::text);
  select count(*) into n from public.notifications where user_id = b and kind = 'reminder_check_in';
  perform pg_temp.ok(n = 0, 'no reminder for the employee who turned it off', n::text);

  -- nobody else can call the trigger function
  s := pg_temp.err('set local role authenticated; select private.default_notification_settings()');
  perform pg_temp.ok(s <> '', 'the trigger function is not callable by users', s);
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
