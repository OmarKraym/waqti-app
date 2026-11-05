-- Rollback of phase 18b: back to phase 18a (no administration leave days). The leave already recorded for such days stays
-- as ordinary approved leave (only its link to the day is removed).
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

create or replace function public.admin_list_requests(p_status text DEFAULT NULL::text, p_type text DEFAULT NULL::text, p_employee_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  return jsonb_build_object(
    'total', (select count(*) from public.requests r
              where r.company_id = v_company
                and exists (select 1 from public.request_approvals a
                            where a.request_id = r.id and a.approver_kind = 'hr' and a.status in ('pending', 'approved', 'rejected'))
                and (p_status is null or r.status::text = p_status)
                and (p_type is null or r.request_type::text = p_type)
                and (p_employee_id is null or r.employee_id = p_employee_id)),
    'items', coalesce((
      select jsonb_agg(private.request_json(x.id) order by x.created_at desc)
      from (select r.id, r.created_at from public.requests r
            where r.company_id = v_company
              and exists (select 1 from public.request_approvals a
                          where a.request_id = r.id and a.approver_kind = 'hr' and a.status in ('pending', 'approved', 'rejected'))
              and (p_status is null or r.status::text = p_status)
              and (p_type is null or r.request_type::text = p_type)
              and (p_employee_id is null or r.employee_id = p_employee_id)
            order by r.created_at desc
            limit greatest(least(coalesce(p_limit, 50), 500), 1) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb));
end;
$function$;
revoke all on function public.admin_list_requests(text, text, uuid, integer, integer) from public, anon;
grant execute on function public.admin_list_requests(text, text, uuid, integer, integer) to authenticated;

create or replace function private.request_json(p_request uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'type', r.request_type, 'leave_type', r.leave_type, 'status', r.status,
    'permission_type_id', r.permission_type_id, 'permission_type', pt.name,
    'start_at', r.start_at, 'end_at', r.end_at, 'days', r.days, 'charged_days', r.charged_days, 'minutes', r.minutes,
    'reason', r.reason, 'decision_note', r.decision_note, 'decided_at', r.decided_at,
    'created_at', r.created_at, 'current_step', r.current_step,
    'employee', jsonb_build_object('full_name', e.full_name, 'employee_number', e.employee_number,
                                   'department', e.department, 'job_title', e.job_title),
    'steps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'step_order', a.step_order, 'kind', a.approver_kind, 'status', a.status,
               'approver_name', ae.full_name, 'decided_at', a.decided_at, 'note', a.note)
             order by a.step_order)
      from public.request_approvals a
      left join public.employees ae on ae.id = a.approver_employee_id
      where a.request_id = r.id), '[]'::jsonb))
  from public.requests r
  join public.employees e on e.id = r.employee_id
  left join public.permission_types pt on pt.id = r.permission_type_id
  where r.id = p_request
$$;
revoke all on function private.request_json(uuid) from public, anon, authenticated;

drop function if exists public.admin_cancel_leave_day(uuid);
drop function if exists public.admin_save_leave_day(uuid, text, date, date, text, text, text);
drop function if exists public.admin_list_leave_days();
drop function if exists private.leave_day_json(public.company_leave_days);
drop function if exists private.apply_company_leave_days(timestamptz);
drop function if exists private.leave_day_rules_text(text, text, text);
drop function if exists private.leave_day_on(uuid, date);
drop index if exists public.requests_company_leave_day_idx;
alter table public.requests drop column if exists company_leave_day_id;
drop table if exists public.company_leave_days;
