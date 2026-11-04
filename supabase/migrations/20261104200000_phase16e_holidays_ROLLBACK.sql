-- Rollback of phase 16e: no holidays. leave_days and enqueue_due_reminders as in phases 4 and 5.
drop function if exists public.employee_calendar();
drop function if exists public.admin_set_holiday_settings(boolean, boolean, integer, boolean, text);
drop function if exists public.admin_get_holiday_settings();
drop function if exists public.admin_delete_holiday(uuid);
drop function if exists public.admin_save_holiday(uuid, text, date, date);
drop function if exists public.admin_list_holidays();
create or replace function private.leave_days(p_employee uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::numeric
  from generate_series(p_from, p_to, interval '1 day') as d
  where not exists (select 1 from public.employee_work_schedules w where w.employee_id = p_employee)
     or exists (select 1 from public.employee_work_schedules w
                where w.employee_id = p_employee and w.weekday = extract(dow from d)::int and w.is_workday)
$$;
revoke all on function private.leave_days(uuid, date, date) from public, anon, authenticated;
create or replace function private.enqueue_due_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
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

  delete from public.reminder_log where day < (p_now at time zone 'UTC')::date - 7;
  delete from public.notifications where created_at < p_now - interval '30 days';
  return v_count;
end;
$$;
revoke all on function private.enqueue_due_reminders(timestamptz) from public, anon, authenticated;
drop function if exists private.notify_holiday(uuid, text, text);
drop function if exists private.holiday_range_text(date, date);
drop function if exists private.holiday_on(uuid, date);
delete from public.reminder_log where kind = 'holiday';
alter table public.reminder_log drop constraint reminder_log_kind_check;
alter table public.reminder_log add constraint reminder_log_kind_check check (kind in ('check_in', 'check_out'));
delete from public.notifications where kind = 'holiday';
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check check (kind in ('approval_needed', 'request_decided',
  'reminder_check_in', 'reminder_check_out', 'test', 'overtime_assigned', 'overtime_cancelled', 'overtime_note'));
drop table if exists public.company_holidays;
alter table public.companies
  drop constraint if exists companies_holiday_ot_min_check,
  drop constraint if exists companies_weekly_off_label_check,
  drop column if exists holiday_deduct_leave,
  drop column if exists holiday_notify_day_before,
  drop column if exists holiday_ot_min_minutes,
  drop column if exists holiday_ot_full_shift,
  drop column if exists weekly_off_label;
