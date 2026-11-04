-- Phase 16f: yearly holidays, and cancelled holidays that stay visible to employees until their date has passed (Omar, 2026-11-04).
--   company_holidays.repeats_yearly   the same days every year, from the year it was added (Feb 29 -> Feb 28)
--   company_holidays.cancelled_at     "delete" now cancels: the row stays, the day is a work day again, the employee app shows
--                                     it as cancelled until its date has passed. Cancelling a yearly holiday stops the series.
--   private.holiday_occurrences(company, from, to)   every occurrence (one-time and yearly) that touches [from, to]
--   holiday_on, employee_calendar, admin_list_holidays, admin_save_holiday (+ p_repeats), admin_delete_holiday (= cancel)
--   and the evening-before notice all go through the occurrences.
-- Rollback: 20261104210000_phase16f_holiday_repeat_cancel_ROLLBACK.sql

do $guard$
begin
  if to_regclass('public.company_holidays') is null
     or to_regprocedure('private.holiday_on(uuid, date)') is null
     or to_regprocedure('public.admin_save_holiday(uuid, text, date, date)') is null then
    raise exception 'phase16f: phase 16e must be applied first';
  end if;
end
$guard$;

alter table public.company_holidays
  add column if not exists repeats_yearly boolean not null default false,
  add column if not exists cancelled_at timestamptz;

-- ---------------------------------------------------------------- occurrences
create or replace function private.holiday_occurrences(p_company uuid, p_from date, p_to date)
returns table (id uuid, name text, start_date date, end_date date, repeats_yearly boolean, cancelled boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select h.id, h.name, h.start_date, h.end_date, false, h.cancelled_at is not null
  from public.company_holidays h
  where h.company_id = p_company and not h.repeats_yearly and h.start_date <= p_to and h.end_date >= p_from
  union all
  select h.id, h.name, o.s, o.s + (h.end_date - h.start_date), true, h.cancelled_at is not null
  from public.company_holidays h
  cross join lateral generate_series(greatest(extract(year from h.start_date)::int, extract(year from p_from)::int - 1),
                                     extract(year from p_to)::int) as y(yr)
  cross join lateral (select (h.start_date + make_interval(years => y.yr - extract(year from h.start_date)::int))::date as s) o
  where h.company_id = p_company and h.repeats_yearly
    and o.s <= p_to and o.s + (h.end_date - h.start_date) >= p_from
$$;
revoke all on function private.holiday_occurrences(uuid, date, date) from public, anon, authenticated;

create or replace function private.holiday_on(p_company uuid, p_day date)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name from private.holiday_occurrences(p_company, p_day, p_day) o
  where not o.cancelled
  order by o.start_date limit 1
$$;
revoke all on function private.holiday_on(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin
-- Next date of a holiday from a day on (the stored dates for a one-time holiday).
create or replace function private.holiday_next(h public.company_holidays, p_today date)
returns table (start_date date, end_date date)
language sql
stable
set search_path = ''
as $$
  select o.start_date, o.end_date
  from private.holiday_occurrences(h.company_id, p_today, p_today + 800) o
  where o.id = h.id
  order by o.start_date limit 1
$$;
revoke all on function private.holiday_next(public.company_holidays, date) from public, anon, authenticated;

create or replace function public.admin_list_holidays()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_today date;
begin
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'start_date', h.start_date, 'end_date', h.end_date,
                                        'days', h.end_date - h.start_date + 1, 'repeats_yearly', h.repeats_yearly,
                                        'cancelled', h.cancelled_at is not null,
                                        'next_start', n.start_date, 'next_end', n.end_date)
                     order by (h.cancelled_at is not null), coalesce(n.start_date, h.start_date) desc)
    from public.company_holidays h
    left join lateral private.holiday_next(h, v_today) n on true
    where h.company_id = v_company), '[]'::jsonb);
end;
$$;
revoke all on function public.admin_list_holidays() from public, anon;
grant execute on function public.admin_list_holidays() to authenticated;

drop function if exists public.admin_save_holiday(uuid, text, date, date);
create or replace function public.admin_save_holiday(p_id uuid, p_name text, p_start date, p_end date, p_repeats boolean default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_old public.company_holidays;
  v_id uuid;
  v_today date;
  v_repeats boolean;
  v_next_start date;
  v_next_end date;
begin
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  if length(v_name) not between 1 and 60 or p_start is null or p_end is null or p_end < p_start
     or p_end - p_start > 60 or p_start < v_today - 3660 or p_start > v_today + 800 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_id is null then
    v_repeats := coalesce(p_repeats, false);
    insert into public.company_holidays (company_id, name, start_date, end_date, created_by, repeats_yearly)
    values (v_company, v_name, p_start, p_end, auth.uid(), v_repeats) returning id into v_id;
  else
    select * into v_old from public.company_holidays where id = p_id and company_id = v_company for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0001';
    end if;
    v_repeats := coalesce(p_repeats, v_old.repeats_yearly);
    update public.company_holidays
       set name = v_name, start_date = p_start, end_date = p_end, repeats_yearly = v_repeats, cancelled_at = null
     where id = p_id;
    v_id := p_id;
  end if;
  perform public.audit_write(v_company, 'holiday.saved', 'holiday', v_id::text,
    jsonb_build_object('name', v_name, 'start_date', p_start, 'end_date', p_end, 'repeats_yearly', v_repeats, 'new', p_id is null));
  select n.start_date, n.end_date into v_next_start, v_next_end
  from public.company_holidays h, private.holiday_next(h, v_today) n where h.id = v_id;
  -- Tell the employees (new, changed or brought back), if it has a date still to come.
  if v_next_start is not null and (p_id is null or v_old.cancelled_at is not null or v_old.start_date <> p_start
      or v_old.end_date <> p_end or v_old.name <> v_name or v_old.repeats_yearly <> v_repeats) then
    perform private.notify_holiday(v_company,
      case when p_id is null then 'عطلة رسمية' else 'تعديل عطلة رسمية' end,
      'عطلة رسمية: ' || v_name || private.holiday_range_text(v_next_start, v_next_end)
        || case when v_repeats then ' (كل سنة)' else '' end || '.');
  end if;
  return jsonb_build_object('id', v_id, 'name', v_name, 'start_date', p_start, 'end_date', p_end, 'days', p_end - p_start + 1,
                            'repeats_yearly', v_repeats, 'cancelled', false, 'next_start', v_next_start, 'next_end', v_next_end);
end;
$$;
revoke all on function public.admin_save_holiday(uuid, text, date, date, boolean) from public, anon;
grant execute on function public.admin_save_holiday(uuid, text, date, date, boolean) to authenticated;

-- "Delete" = cancel: the row stays so employees see "cancelled" until the date has passed.
create or replace function public.admin_delete_holiday(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_old public.company_holidays;
  v_today date;
  v_next_start date;
  v_next_end date;
begin
  select * into v_old from public.company_holidays where id = p_id and company_id = v_company for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v_old.cancelled_at is not null then
    return jsonb_build_object('ok', true);
  end if;
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  select n.start_date, n.end_date into v_next_start, v_next_end from private.holiday_next(v_old, v_today) n;
  update public.company_holidays set cancelled_at = now() where id = p_id;
  perform public.audit_write(v_company, 'holiday.cancelled', 'holiday', p_id::text,
    jsonb_build_object('name', v_old.name, 'start_date', v_old.start_date, 'end_date', v_old.end_date, 'repeats_yearly', v_old.repeats_yearly));
  if v_next_start is not null then
    perform private.notify_holiday(v_company, 'إلغاء عطلة رسمية',
      'أُلغيت العطلة الرسمية: ' || v_old.name || private.holiday_range_text(v_next_start, v_next_end) || '. الدوام كالمعتاد.');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_delete_holiday(uuid) from public, anon;
grant execute on function public.admin_delete_holiday(uuid) to authenticated;

-- ---------------------------------------------------------------- employee
create or replace function public.employee_calendar()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me record;
  v_today date;
begin
  select * into me from public.require_active_employee();
  v_today := (now() at time zone me.timezone)::date;
  return jsonb_build_object(
    'weekly_off_label', (select c.weekly_off_label from public.companies c where c.id = me.company_id),
    'today_holiday', private.holiday_on(me.company_id, v_today),
    -- every holiday still to come (or going on today), cancelled ones included: they disappear once their date has passed
    'holidays', coalesce((
      select jsonb_agg(jsonb_build_object('name', o.name, 'start_date', o.start_date, 'end_date', o.end_date,
                                          'repeats_yearly', o.repeats_yearly, 'cancelled', o.cancelled) order by o.start_date)
      from (select distinct on (x.id) x.* from private.holiday_occurrences(me.company_id, v_today, v_today + 366) x
            order by x.id, x.start_date) o), '[]'::jsonb));
end;
$$;
revoke all on function public.employee_calendar() from public, anon;
grant execute on function public.employee_calendar() to authenticated;

-- ---------------------------------------------------------------- evening-before notice through the occurrences
create or replace function private.enqueue_due_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_hol record;
  v_emp_id uuid;
  v_count int := 0;
begin
  for r in
    select s.employee_id, s.company_id, s.remind_check_in, s.check_in_before, s.remind_check_out, s.check_out_before,
           c.timezone, (p_now at time zone c.timezone)::date as day, b.shift_start, b.shift_end
    from public.notification_settings s
    join public.employees e on e.id = s.employee_id and e.is_active
    join public.companies c on c.id = s.company_id and c.is_active
    cross join lateral private.shift_bounds(s.employee_id, (p_now at time zone c.timezone)::date, c.timezone) b
    where (s.remind_check_in or s.remind_check_out)
      and exists (select 1 from public.push_subscriptions p where p.user_id = s.employee_id)
      and private.holiday_on(s.company_id, (p_now at time zone c.timezone)::date) is null
  loop
    -- check-in: before the shift start, only if not checked in today and not on approved leave
    if r.remind_check_in
       and p_now >= r.shift_start - make_interval(mins => r.check_in_before)
       and p_now < r.shift_start - make_interval(mins => r.check_in_before) + interval '15 minutes'
       and not exists (select 1 from public.attendance_events ev
                       where ev.employee_id = r.employee_id and ev.event_type = 'check_in'
                         and (ev.occurred_at at time zone r.timezone)::date = r.day)
       and not exists (select 1 from public.attendance_sessions se where se.employee_id = r.employee_id and se.status = 'open')
       and not exists (select 1 from public.requests q
                       where q.employee_id = r.employee_id and q.request_type = 'leave' and q.status = 'approved'
                         and q.start_at <= r.shift_start and q.end_at > r.shift_start) then
      insert into public.reminder_log (employee_id, day, kind) values (r.employee_id, r.day, 'check_in') on conflict do nothing;
      if found then
        perform private.notify(r.employee_id, r.company_id, 'reminder_check_in', 'تذكير بتسجيل الحضور',
          case when r.check_in_before = 0 then 'بدأ دوامك الآن (' else 'يبدأ دوامك الساعة ' end
            || to_char(r.shift_start at time zone r.timezone, 'HH24:MI')
            || case when r.check_in_before = 0 then '). ' else '. ' end || 'لا تنسَ تسجيل الحضور.',
          './', 'reminder-in', 900);
        v_count := v_count + 1;
      end if;
    end if;

    -- check-out: before the shift end, only if checked in (open session)
    if r.remind_check_out
       and p_now >= r.shift_end - make_interval(mins => r.check_out_before)
       and p_now < r.shift_end - make_interval(mins => r.check_out_before) + interval '15 minutes'
       and exists (select 1 from public.attendance_sessions se where se.employee_id = r.employee_id and se.status = 'open') then
      insert into public.reminder_log (employee_id, day, kind) values (r.employee_id, r.day, 'check_out') on conflict do nothing;
      if found then
        perform private.notify(r.employee_id, r.company_id, 'reminder_check_out', 'تذكير بتسجيل الانصراف',
          case when r.check_out_before = 0 then 'انتهى دوامك الآن (' else 'ينتهي دوامك الساعة ' end
            || to_char(r.shift_end at time zone r.timezone, 'HH24:MI')
            || case when r.check_out_before = 0 then '). ' else '. ' end || 'لا تنسَ تسجيل الانصراف.',
          './', 'reminder-out', 900);
        v_count := v_count + 1;
      end if;
    end if;
  end loop;

  -- Official holiday tomorrow (phase 16e): one notice the evening before (from 18:00), if the company switched it on.
  for v_hol in
    select c.id as company_id, o.name, o.start_date, o.end_date
    from public.companies c
    cross join lateral private.holiday_occurrences(c.id, (p_now at time zone c.timezone)::date + 1, (p_now at time zone c.timezone)::date + 1) o
    where c.is_active and c.holiday_notify_day_before and not o.cancelled
      and o.start_date = (p_now at time zone c.timezone)::date + 1
      and (p_now at time zone c.timezone)::time >= time '18:00'
  loop
    for v_emp_id in
      select em.id from public.employees em
      where em.company_id = v_hol.company_id and em.is_active
        and exists (select 1 from public.push_subscriptions p where p.user_id = em.id)
    loop
      insert into public.reminder_log (employee_id, day, kind) values (v_emp_id, v_hol.start_date, 'holiday') on conflict do nothing;
      if found then
        perform private.notify(v_emp_id, v_hol.company_id, 'holiday', 'عطلة رسمية غداً',
          'غداً عطلة رسمية: ' || v_hol.name || private.holiday_range_text(v_hol.start_date, v_hol.end_date) || '.', './', 'holiday-before', 43200);
        v_count := v_count + 1;
      end if;
    end loop;
  end loop;

  delete from public.reminder_log where day < (p_now at time zone 'UTC')::date - 7;
  delete from public.notifications where created_at < p_now - interval '30 days';
  return v_count;
end;
$$;
revoke all on function private.enqueue_due_reminders(timestamptz) from public, anon, authenticated;

