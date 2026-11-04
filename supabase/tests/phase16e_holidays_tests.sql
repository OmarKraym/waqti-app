-- Phase 16e: official holidays and their settings.
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
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.try_as(u uuid, q text) returns text language plpgsql as $$
declare s text;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  s := pg_temp.err(q);
  reset role;
  return s;
end $$;
create function pg_temp.run_as(u uuid, q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q into r;
  reset role;
  return r;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; v_comp2 uuid; e2 uuid; r jsonb; s text; n int; v_id uuid; v_today date; d date; v_start timestamptz;
  k_p256dh text := 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM';
  k_auth text := 'tBHItJI5svbpez7KI4CCXg';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone 'Africa/Tripoli')::date;
  delete from public.notifications;
  -- a Sunday-Wednesday stretch well ahead (all work days in the seed: only Friday is off)
  d := v_today + 1; -- near today: the reminder job deletes notifications older than 30 days before its "now"
  while extract(dow from d) <> 0 loop d := d + 1; end loop;

  -- ---------------------------------------------------------------- settings
  r := pg_temp.run_as(v_admin, 'select public.admin_get_holiday_settings()');
  perform pg_temp.ok(r = '{"deduct_leave": true, "notify_day_before": false, "ot_min_minutes": 60, "ot_full_shift": true, "weekly_off_label": "عطلة رسمية"}'::jsonb,
                     'defaults: deduct from leave, notify on add only, OT from 1 hour as a full shift, label «عطلة رسمية»', r::text);
  s := pg_temp.try_as(a, 'select public.admin_get_holiday_settings()');
  perform pg_temp.ok(s = 'forbidden', 'employees cannot read the holiday settings', s);
  s := pg_temp.try_as(v_admin, 'select public.admin_set_holiday_settings(true, false, 900, true, ''x'')');
  perform pg_temp.ok(s = 'invalid_input', 'OT minimum over 12 hours is refused', s);
  s := pg_temp.try_as(v_admin, 'select public.admin_set_holiday_settings(true, false, 60, true, '''')');
  perform pg_temp.ok(s = 'invalid_input', 'empty label is refused', s);

  -- ---------------------------------------------------------------- add a holiday
  perform pg_temp.as_user(a);
  perform public.employee_save_push_subscription('https://fcm.googleapis.com/fcm/send/hol-a', k_p256dh, k_auth, 'test');
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'عيد الاستقلال', d + 1, d + 2));
  v_id := (r ->> 'id')::uuid;
  perform pg_temp.ok(v_id is not null and r ->> 'name' = 'عيد الاستقلال', 'admin adds a holiday', r::text);
  select count(*) into n from public.notifications where kind = 'holiday' and user_id = a and body like '%عيد الاستقلال%';
  perform pg_temp.ok(n = 1, 'employees are notified when it is added', n::text);
  select count(*) into n from public.notifications where kind = 'holiday';
  perform pg_temp.ok(n = (select count(distinct p.user_id) from public.push_subscriptions p join public.employees e on e.id = p.user_id
                          where e.company_id = v_comp and e.is_active), 'every active employee with a device, once', n::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'holiday.saved' and target_id = v_id::text) = 1, 'audit: holiday.saved');

  for s in select unnest(array[
    format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', '', d, d),
    format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'x', d + 2, d),
    format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'x', d, d + 90)]) loop
    perform pg_temp.ok(pg_temp.try_as(v_admin, s) = 'invalid_input', 'refused: ' || s);
  end loop;
  s := pg_temp.try_as(a, format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'x', d, d));
  perform pg_temp.ok(s = 'forbidden', 'employees cannot add holidays', s);

  r := pg_temp.run_as(v_admin, 'select public.admin_list_holidays()');
  perform pg_temp.ok(jsonb_array_length(r) = 1 and (r -> 0 ->> 'days')::int = 2, 'admin lists holidays with their length', r::text);

  -- ---------------------------------------------------------------- the employee sees it
  r := pg_temp.run_as(a, 'select public.employee_calendar()');
  perform pg_temp.ok(r ->> 'weekly_off_label' = 'عطلة رسمية' and jsonb_array_length(r -> 'holidays') = 1
                     and r -> 'holidays' -> 0 ->> 'name' = 'عيد الاستقلال' and r ->> 'today_holiday' is null,
                     'employee calendar: label and upcoming holiday', r::text);
  perform pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'اليوم', v_today, v_today));
  r := pg_temp.run_as(a, 'select public.employee_calendar()');
  perform pg_temp.ok(r ->> 'today_holiday' = 'اليوم', 'today is a holiday: the app knows', r::text);

  -- ---------------------------------------------------------------- leave over a holiday
  perform pg_temp.ok(private.leave_days(a, d, d + 3) = 4, 'deduct ON (default): holiday days count as leave days');
  perform pg_temp.run_as(v_admin, 'select public.admin_set_holiday_settings(false, false, 60, true, ''عطلة رسمية'')');
  perform pg_temp.ok(private.leave_days(a, d, d + 3) = 2, 'deduct OFF: the 2 holiday days are not taken from the balance');
  perform pg_temp.ok(private.leave_days(a, d + 1, d + 2) = 0, 'deduct OFF: a leave only on the holiday has no days');
  perform pg_temp.run_as(v_admin, 'select public.admin_set_holiday_settings(true, false, 60, true, ''عطلة رسمية'')');

  -- ---------------------------------------------------------------- reminders
  delete from public.reminder_log;
  delete from public.notifications;
  select shift_start into v_start from private.shift_bounds(a, d + 1, 'Africa/Tripoli');
  perform set_config('role', 'none', true);
  perform private.enqueue_due_reminders(v_start - interval '5 minutes');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'reminder_check_in') = 0, 'no punch reminder on a holiday');
  select shift_start into v_start from private.shift_bounds(a, d, 'Africa/Tripoli');
  perform private.enqueue_due_reminders(v_start - interval '5 minutes');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'reminder_check_in') = 1, '... but on the day before, yes');

  -- the day before: only when switched on, at 18:00, once
  perform private.enqueue_due_reminders(((d) + time '18:30') at time zone 'Africa/Tripoli');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'holiday') = 0, 'notify-day-before OFF: nothing');
  perform pg_temp.run_as(v_admin, 'select public.admin_set_holiday_settings(true, true, 60, true, ''عطلة رسمية'')');
  perform private.enqueue_due_reminders(((d) + time '17:00') at time zone 'Africa/Tripoli');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'holiday') = 0, 'ON: not before 18:00');
  perform private.enqueue_due_reminders(((d) + time '18:01') at time zone 'Africa/Tripoli');
  perform private.enqueue_due_reminders(((d) + time '19:00') at time zone 'Africa/Tripoli');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'holiday' and body like '%غداً%') = 1, 'ON: the evening before, once');

  -- ---------------------------------------------------------------- edit, label, delete
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(%L, %L, %L::date, %L::date)', v_id, 'عيد الاستقلال (معدّل)', d + 1, d + 1));
  perform pg_temp.ok(r ->> 'name' = 'عيد الاستقلال (معدّل)' and (r ->> 'end_date')::date = d + 1, 'admin edits a holiday', r::text);
  perform pg_temp.run_as(v_admin, 'select public.admin_set_holiday_settings(true, false, 30, false, ''يوم راحة'')');
  r := pg_temp.run_as(a, 'select public.employee_calendar()');
  perform pg_temp.ok(r ->> 'weekly_off_label' = 'يوم راحة', 'the weekly day-off label is the admin''s text', r::text);
  r := pg_temp.run_as(v_admin, 'select public.admin_get_holiday_settings()');
  perform pg_temp.ok((r ->> 'ot_min_minutes')::int = 30 and r ->> 'ot_full_shift' = 'false', 'OT rule saved', r::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'holiday.settings') >= 1, 'audit: holiday.settings');

  delete from public.notifications;
  r := pg_temp.run_as(v_admin, format('select public.admin_delete_holiday(%L)', v_id));
  -- since phase 16f "delete" cancels: the row stays (employees see it as cancelled until its date has passed)
  perform pg_temp.ok(private.holiday_on(v_comp, d + 1) is null and exists (select 1 from public.company_holidays where id = v_id and cancelled_at is not null),
                     'admin cancels a holiday');
  perform pg_temp.ok((select count(*) from public.notifications where user_id = a and kind = 'holiday' and body like '%أُلغيت%') = 1, 'employees are told it was cancelled');

  -- ---------------------------------------------------------------- isolation
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار العطل', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'hol-iso@example.com', jsonb_build_object('company_id', v_comp2, 'company_role', 'company_admin'), '{"full_name":"مدير آخر"}')
  returning id into e2;
  r := pg_temp.run_as(e2, 'select public.admin_list_holidays()');
  perform pg_temp.ok(jsonb_array_length(r) = 0, 'another company sees none of these holidays', r::text);
  s := pg_temp.try_as(e2, format('select public.admin_delete_holiday(%L)', (select id from public.company_holidays where company_id = v_comp limit 1)));
  perform pg_temp.ok(s = 'not_found', 'and cannot delete them', s);
  perform pg_temp.ok(not has_function_privilege('anon', 'public.employee_calendar()', 'execute'), 'anonymous cannot read the calendar');
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
