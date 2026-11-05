-- Phase 18b: days the administration makes annual leave (Omar, 2026-11-05), e.g. the Thursday between Eid and the weekend.
--   public.company_leave_days: name, days, and the rules the admin picked for it:
--     scope        'absent' = annual leave for whoever did not check in that day
--                  'all'    = annual leave for everyone
--     worked_rule  (scope 'all') someone came and checked in: 'no_deduct' (a normal work day) | 'deduct' |
--                  'deduct_overtime' (deducted, and the time worked is overtime: the panel report)
--     short_rule   the balance does not cover it: 'negative' (taken anyway, the balance goes below zero) |
--                  'unpaid' (what is not covered is unpaid leave)
--   Once a day is over, every active employee who works that day gets an approved annual (or unpaid) leave request,
--   linked to the day (requests.company_leave_day_id), once (deterministic request_key). Run every minute from
--   private.enqueue_due_reminders. Employees who already have a leave that day are left alone.
--   Shown in the employee app's holidays card (employee_calendar, kind 'annual_leave') with its rules; everybody is
--   notified when it is added, changed or cancelled. Cancelling after the day cancels the leave it created.
--   No reminders are sent on such a day.
-- Rollback: 20261105100000_phase18b_company_leave_days_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('private.leave_balance(uuid, text, integer, uuid, date)') is null
     or to_regprocedure('private.holiday_occurrences(uuid, date, date)') is null
     or to_regprocedure('private.notify_holiday(uuid, text, text)') is null
     or to_regprocedure('private.enqueue_due_reminders(timestamptz)') is null then
    raise exception 'phase18b: phases 16f and 18a must be applied first';
  end if;
end
$guard$;

create table if not exists public.company_leave_days (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 60),
  start_date date not null,
  end_date date not null,
  scope text not null check (scope in ('absent', 'all')),
  worked_rule text not null default 'no_deduct' check (worked_rule in ('no_deduct', 'deduct', 'deduct_overtime')),
  short_rule text not null default 'negative' check (short_rule in ('negative', 'unpaid')),
  applied_through date,          -- last day already recorded (null = none yet)
  cancelled_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (end_date >= start_date and end_date - start_date <= 30)
);
create index if not exists company_leave_days_company_idx on public.company_leave_days (company_id, start_date);
alter table public.company_leave_days enable row level security;
revoke all on public.company_leave_days from public, anon, authenticated;

alter table public.requests
  add column if not exists company_leave_day_id uuid references public.company_leave_days (id) on delete set null;
create index if not exists requests_company_leave_day_idx on public.requests (company_leave_day_id) where company_leave_day_id is not null;

-- The active (not cancelled) administration leave day covering a date, if any.
create or replace function private.leave_day_on(p_company uuid, p_day date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.id from public.company_leave_days l
  where l.company_id = p_company and l.cancelled_at is null and p_day between l.start_date and l.end_date
  order by l.created_at limit 1
$$;
revoke all on function private.leave_day_on(uuid, date) from public, anon, authenticated;

-- The text of the rules, for notices: "لمن لم يبصم" / "للجميع..." and what happens when the balance is short.
create or replace function private.leave_day_rules_text(p_scope text, p_worked text, p_short text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_scope = 'absent' then 'تُخصم من رصيد من لا يحضر ولا يبصم.'
              else 'تُخصم من رصيد الجميع' || case p_worked when 'no_deduct' then '، ومن يحضر ويبصم لا تُخصم منه.'
                                                          when 'deduct' then ' حتى من يحضر.'
                                                          else '، ومن يحضر يُحسب وقته عملًا إضافيًا.' end end
         || case when p_short = 'unpaid' then ' إن لم يكفِ رصيدك تُسجّل بدون راتب.' else ' إن لم يكفِ رصيدك تُخصم ويصبح رصيدك بالسالب.' end
$$;
revoke all on function private.leave_day_rules_text(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- recording the leave once a day is over
create or replace function private.apply_company_leave_days(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  l record;
  e record;
  d date;
  v_today date;
  v_last date;
  v_days numeric;
  v_worked boolean;
  v_bal jsonb;
  v_left numeric;
  v_type text;
  v_charged numeric;
  v_count int := 0;
begin
  for l in
    select ld.*, c.timezone from public.company_leave_days ld join public.companies c on c.id = ld.company_id and c.is_active
    where ld.cancelled_at is null
      and coalesce(ld.applied_through, ld.start_date - 1) < least(ld.end_date, (p_now at time zone c.timezone)::date - 1)
    for update of ld skip locked
  loop
    v_today := (p_now at time zone l.timezone)::date;
    v_last := least(l.end_date, v_today - 1);
    for d in select g::date from generate_series(greatest(l.start_date, coalesce(l.applied_through + 1, l.start_date)), v_last, interval '1 day') g loop
      for e in
        select em.id from public.employees em
        where em.company_id = l.company_id and em.is_active and (em.hire_date is null or em.hire_date <= d)
        order by em.id
      loop
        -- one lock per employee, as employee_submit_request does (the balance stays right)
        perform 1 from public.employees where id = e.id for update;
        v_days := private.leave_days(e.id, d, d);
        continue when v_days = 0;                                         -- not his work day (or an official holiday)
        continue when exists (select 1 from public.requests r
                              where r.employee_id = e.id and r.request_type = 'leave' and r.status in ('pending', 'approved')
                                and tstzrange(r.start_at, r.end_at, '[)') && tstzrange(d::timestamp at time zone l.timezone,
                                                                                        (d + 1)::timestamp at time zone l.timezone, '[)'));
        v_worked := exists (select 1 from public.attendance_events ev
                            where ev.employee_id = e.id and ev.event_type = 'check_in'
                              and (ev.occurred_at at time zone l.timezone)::date = d);
        continue when v_worked and (l.scope = 'absent' or l.worked_rule = 'no_deduct');
        v_type := 'annual';
        v_charged := null;
        if l.short_rule = 'unpaid' then
          v_bal := private.leave_balance(e.id, 'annual', extract(year from d)::int, null, d);
          v_left := (v_bal ->> 'remaining')::numeric;
          if v_left <= 0 then
            v_type := 'unpaid';
          elsif v_left < v_days then
            v_charged := round(floor(v_left * 2) / 2, 1);                 -- the rest is unpaid
          end if;
        end if;
        insert into public.requests (employee_id, request_type, leave_type, status, start_at, end_at, reason, days, charged_days,
                                     request_key, decided_at, company_leave_day_id)
        values (e.id, 'leave', v_type, 'approved', d::timestamp at time zone l.timezone, (d + 1)::timestamp at time zone l.timezone,
                'إجازة سنوية من الإدارة: ' || l.name, v_days, v_charged,
                md5('waqti.leave_day:' || l.id::text || ':' || e.id::text || ':' || d::text)::uuid, now(), l.id)
        on conflict do nothing;
        if found then
          v_count := v_count + 1;
        end if;
      end loop;
    end loop;
    update public.company_leave_days set applied_through = v_last where id = l.id;
  end loop;
  return v_count;
end;
$$;
revoke all on function private.apply_company_leave_days(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin
create or replace function private.leave_day_json(l public.company_leave_days)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('id', l.id, 'name', l.name, 'start_date', l.start_date, 'end_date', l.end_date,
    'days', l.end_date - l.start_date + 1, 'scope', l.scope, 'worked_rule', l.worked_rule, 'short_rule', l.short_rule,
    'applied', l.applied_through is not null, 'cancelled', l.cancelled_at is not null,
    'recorded', (select count(*) from public.requests r where r.company_leave_day_id = l.id and r.status = 'approved'))
$$;
revoke all on function private.leave_day_json(public.company_leave_days) from public, anon, authenticated;

create or replace function public.admin_list_leave_days()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return coalesce((select jsonb_agg(private.leave_day_json(l) order by (l.cancelled_at is not null), l.start_date desc)
                   from public.company_leave_days l where l.company_id = v_company), '[]'::jsonb);
end;
$$;
revoke all on function public.admin_list_leave_days() from public, anon;
grant execute on function public.admin_list_leave_days() to authenticated;

-- New (p_id null) or a change before any day was recorded. Saving a cancelled one brings it back.
create or replace function public.admin_save_leave_day(p_id uuid, p_name text, p_start date, p_end date, p_scope text,
                                                       p_worked_rule text default 'no_deduct', p_short_rule text default 'negative')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_today date;
  v_old public.company_leave_days;
  v_row public.company_leave_days;
begin
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  if length(v_name) not between 1 and 60 or p_start is null or p_end is null or p_end < p_start or p_end - p_start > 30
     or p_start < v_today - 31 or p_start > v_today + 400
     or p_scope not in ('absent', 'all') or coalesce(p_worked_rule, '') not in ('no_deduct', 'deduct', 'deduct_overtime')
     or coalesce(p_short_rule, '') not in ('negative', 'unpaid') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_id is null then
    insert into public.company_leave_days (company_id, name, start_date, end_date, scope, worked_rule, short_rule, created_by)
    values (v_company, v_name, p_start, p_end, p_scope, case when p_scope = 'all' then p_worked_rule else 'no_deduct' end,
            p_short_rule, auth.uid())
    returning * into v_row;
  else
    select * into v_old from public.company_leave_days where id = p_id and company_id = v_company for update;
    if not found then
      raise exception 'not_found' using errcode = 'P0001';
    end if;
    if v_old.applied_through is not null then
      raise exception 'already_applied' using errcode = 'P0001';  -- leave was recorded already: cancel and add a new one
    end if;
    update public.company_leave_days
       set name = v_name, start_date = p_start, end_date = p_end, scope = p_scope,
           worked_rule = case when p_scope = 'all' then p_worked_rule else 'no_deduct' end, short_rule = p_short_rule,
           cancelled_at = null
     where id = p_id
    returning * into v_row;
  end if;
  perform public.audit_write(v_company, 'leave_day.saved', 'leave_day', v_row.id::text, private.leave_day_json(v_row));
  if v_row.end_date >= v_today then
    perform private.notify_holiday(v_company,
      case when p_id is null then 'إجازة سنوية من الإدارة' else 'تعديل إجازة سنوية من الإدارة' end,
      v_name || private.holiday_range_text(v_row.start_date, v_row.end_date) || ': '
        || private.leave_day_rules_text(v_row.scope, v_row.worked_rule, v_row.short_rule));
  end if;
  return private.leave_day_json(v_row);
end;
$$;
revoke all on function public.admin_save_leave_day(uuid, text, date, date, text, text, text) from public, anon;
grant execute on function public.admin_save_leave_day(uuid, text, date, date, text, text, text) to authenticated;

-- Cancel: no more leave is recorded, and the leave already recorded for it is cancelled (it goes back to the balance).
create or replace function public.admin_cancel_leave_day(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_row public.company_leave_days;
  v_today date;
  v_undone int;
begin
  select * into v_row from public.company_leave_days where id = p_id and company_id = v_company for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if v_row.cancelled_at is not null then
    return private.leave_day_json(v_row);
  end if;
  update public.company_leave_days set cancelled_at = now() where id = p_id returning * into v_row;
  update public.requests set status = 'cancelled', decided_at = now()
   where company_leave_day_id = p_id and status = 'approved';
  get diagnostics v_undone = row_count;
  perform public.audit_write(v_company, 'leave_day.cancelled', 'leave_day', p_id::text,
    private.leave_day_json(v_row) || jsonb_build_object('leave_cancelled', v_undone));
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  if v_row.end_date >= v_today or v_undone > 0 then
    perform private.notify_holiday(v_company, 'إلغاء إجازة سنوية من الإدارة',
      'أُلغيت الإجازة السنوية: ' || v_row.name || private.holiday_range_text(v_row.start_date, v_row.end_date)
        || case when v_row.end_date >= v_today then '. الدوام كالمعتاد.' else '. لن تُخصم من رصيدك.' end);
  end if;
  return private.leave_day_json(v_row);
end;
$$;
revoke all on function public.admin_cancel_leave_day(uuid) from public, anon;
grant execute on function public.admin_cancel_leave_day(uuid) to authenticated;

-- ---------------------------------------------------------------- employee: the holidays card shows these days too
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
      select jsonb_agg(x.item order by x.start_date)
      from (
        select o.start_date, jsonb_build_object('kind', 'holiday', 'name', o.name, 'start_date', o.start_date, 'end_date', o.end_date,
                                                'repeats_yearly', o.repeats_yearly, 'cancelled', o.cancelled) as item
        from (select distinct on (x.id) x.* from private.holiday_occurrences(me.company_id, v_today, v_today + 366) x
              order by x.id, x.start_date) o
        union all
        -- days the administration made annual leave (phase 18b), with its rules
        select l.start_date, jsonb_build_object('kind', 'annual_leave', 'name', l.name, 'start_date', l.start_date, 'end_date', l.end_date,
                                                'scope', l.scope, 'worked_rule', l.worked_rule, 'short_rule', l.short_rule,
                                                'repeats_yearly', false, 'cancelled', l.cancelled_at is not null)
        from public.company_leave_days l
        where l.company_id = me.company_id and l.end_date >= v_today and l.start_date <= v_today + 366) x), '[]'::jsonb));
end;
$$;
revoke all on function public.employee_calendar() from public, anon;
grant execute on function public.employee_calendar() to authenticated;

-- ---------------------------------------------------------------- every minute: record finished days; no reminders on them
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
  -- Days the administration made annual leave (phase 18b): record the leave of each employee once the day is over.
  perform private.apply_company_leave_days(p_now);

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
      and private.leave_day_on(s.company_id, (p_now at time zone c.timezone)::date) is null
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
