-- Phase 16f: yearly holidays, and cancelled holidays that stay visible to employees until their date has passed.
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
  v_admin uuid; a uuid; v_comp uuid; r jsonb; v_id uuid; v_old uuid; v_today date; d date; y int; n int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone 'Africa/Tripoli')::date;
  y := extract(year from v_today)::int;
  delete from public.notifications;

  -- ---------------------------------------------------------------- a yearly holiday added for LAST year still happens this year
  d := make_date(y - 1, 12, 24);
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date, true)', 'عيد الاستقلال', d, d));
  v_id := (r ->> 'id')::uuid;
  perform pg_temp.ok(r ->> 'repeats_yearly' = 'true', 'the admin marks a holiday as yearly', r::text);
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y, 12, 24)) = 'عيد الاستقلال', 'yearly: it is a holiday this year too');
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y + 3, 12, 24)) = 'عيد الاستقلال', 'yearly: and in later years');
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y - 2, 12, 24)) is null, 'yearly: not before the year it was first added');
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y, 12, 25)) is null, 'yearly: only its own days');

  -- one that crosses the new year
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date, true)', 'رأس السنة', make_date(y - 1, 12, 31), make_date(y, 1, 1)));
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y + 1, 1, 1)) = 'رأس السنة' and private.holiday_on(v_comp, make_date(y, 12, 31)) = 'رأس السنة',
                     'yearly across the new year: both days, every year');

  -- a one-time holiday last year does not come back
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'مرة واحدة', make_date(y - 1, 3, 3), make_date(y - 1, 3, 3)));
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y, 3, 3)) is null, 'one-time (old 4-argument call): not repeated');

  -- ---------------------------------------------------------------- the employee sees the next occurrence
  r := pg_temp.run_as(a, 'select public.employee_calendar()');
  select count(*) into n from jsonb_array_elements(r -> 'holidays') x where x ->> 'name' = 'عيد الاستقلال';
  perform pg_temp.ok(n = 1, 'calendar: the yearly holiday once, at its next date', r::text);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r -> 'holidays') x
                             where x ->> 'name' = 'عيد الاستقلال' and (x ->> 'start_date')::date >= v_today and x ->> 'repeats_yearly' = 'true'
                               and x ->> 'cancelled' = 'false'), 'calendar: next date, marked yearly, not cancelled', r::text);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r -> 'holidays') x where x ->> 'name' = 'مرة واحدة'), 'calendar: past one-time holidays are gone');

  -- ---------------------------------------------------------------- cancelling keeps it visible until its date has passed
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date)', 'عطلة ستُلغى', v_today + 10, v_today + 11));
  v_old := (r ->> 'id')::uuid;
  delete from public.notifications;
  r := pg_temp.run_as(v_admin, format('select public.admin_delete_holiday(%L)', v_old));
  perform pg_temp.ok(exists (select 1 from public.company_holidays where id = v_old and cancelled_at is not null), 'cancel keeps the row (cancelled)');
  perform pg_temp.ok(private.holiday_on(v_comp, v_today + 10) is null, 'a cancelled holiday is a normal work day');
  r := pg_temp.run_as(a, 'select public.employee_calendar()');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r -> 'holidays') x where x ->> 'name' = 'عطلة ستُلغى' and x ->> 'cancelled' = 'true'),
                     'the employee still sees it, marked cancelled', r::text);
  r := pg_temp.run_as(v_admin, 'select public.admin_list_holidays()');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r) x where x ->> 'name' = 'عطلة ستُلغى' and x ->> 'cancelled' = 'true'),
                     'the admin sees it as cancelled', r::text);
  r := pg_temp.run_as(v_admin, format('select public.admin_delete_holiday(%L)', v_old));
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'holiday.cancelled' and target_id = v_old::text) = 1, 'cancelling twice: one audit row');

  -- past cancelled holiday disappears from the employee view
  insert into public.company_holidays (company_id, name, start_date, end_date, cancelled_at)
  values (v_comp, 'ملغاة قديمة', v_today - 5, v_today - 4, now());
  r := pg_temp.run_as(a, 'select public.employee_calendar()');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r -> 'holidays') x where x ->> 'name' = 'ملغاة قديمة'), 'a cancelled holiday is gone once its date has passed', r::text);

  -- editing a cancelled holiday brings it back
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(%L, %L, %L::date, %L::date, false)', v_old, 'عطلة ستُلغى', v_today + 10, v_today + 11));
  perform pg_temp.ok(r ->> 'cancelled' = 'false' and private.holiday_on(v_comp, v_today + 10) = 'عطلة ستُلغى', 'saving a cancelled holiday makes it active again', r::text);

  -- a cancelled yearly holiday stops for every year
  r := pg_temp.run_as(v_admin, format('select public.admin_delete_holiday(%L)', v_id));
  perform pg_temp.ok(private.holiday_on(v_comp, make_date(y + 1, 12, 24)) is null, 'cancelling a yearly holiday stops the series');

  -- leave days follow the occurrences (deduct off)
  perform pg_temp.run_as(v_admin, 'select public.admin_set_holiday_settings(false, false, 60, true, ''عطلة رسمية'')');
  r := pg_temp.run_as(v_admin, format('select public.admin_save_holiday(null, %L, %L::date, %L::date, true)', 'سنوية للإجازة', make_date(y - 1, 6, 1), make_date(y - 1, 6, 1)));
  perform pg_temp.ok(private.leave_days(a, make_date(y + 1, 6, 1), make_date(y + 1, 6, 1)) = 0
                     or extract(dow from make_date(y + 1, 6, 1)) = 5, 'deduct off: a yearly holiday is not a leave day in a later year');
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
