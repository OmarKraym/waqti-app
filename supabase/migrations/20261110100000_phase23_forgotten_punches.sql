-- Phase 23: what the employee forgot shows up for the admin in "movements that need a look" (admin_review_queue + a new list).
--   * An open session nobody closed (a check-in with no check-out): when the admin opens the review queue, every open session of
--     his company that has run past its check-out time is closed as "missed check-out" and flagged for review, exactly like
--     private.close_missed_checkout does when the employee opens the app or punches. The review row then has the existing
--     "add the check-out" button (admin_resolve_review 'add_check_out', phase 20c). Employees the window rule cannot judge (the
--     company has punch windows off, or the employee has no work schedule) are judged by one fixed rule: 24 hours after the check-in.
--   * A check-in nobody made: a working day (his schedule, not a holiday, not an approved leave) of the last 7 days on which the
--     employee has no movement at all and the grace period after his shift start has passed. admin_list_missing_checkins lists them;
--     the admin adds the check-in (admin_add_punch, phase 20) or says "absent" (admin_dismiss_missing_checkin), which hides the row.
--   * A review row on a day the employee has an approved leave for (his own request, not a company holiday) carries that leave in the
--     existing `leave` column of admin_review_queue, so the panel can say "عليه إجازة معتمدة". Nothing is hidden or written: the admin decides.
-- Nothing is deleted. Rollback: *_ROLLBACK.sql (sessions already closed as missed stay missed: that is data, not structure).

-- ---------------------------------------------------------------- the admin's decision "absent" for a day
create table public.attendance_day_decisions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  day date not null,
  decision text not null check (decision in ('absent')),
  note text,
  decided_by uuid,
  decided_at timestamptz not null default now(),
  constraint attendance_day_decisions_employee_day_key unique (employee_id, day)
);
alter table public.attendance_day_decisions enable row level security;
revoke all on public.attendance_day_decisions from anon, authenticated;

-- ---------------------------------------------------------------- open sessions that were forgotten
-- Closes (as "missed check-out", flagged for review) the open sessions of a company that ran past their check-out time. Returns how many.
-- One employee at a time, with the same lock as a punch; an employee who is punching right now is skipped (the next look catches him).
create or replace function private.close_forgotten_sessions(p_company uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_n integer := 0;
  v_on boolean;
  v_sess uuid;
  v_ev uuid;
  v_in timestamptz;
begin
  select c.punch_windows_enabled into v_on from public.companies c where c.id = p_company;
  for r in
    select distinct s.employee_id
    from public.attendance_sessions s join public.employees e on e.id = s.employee_id
    where e.company_id = p_company and s.status = 'open'
  loop
    perform 1 from public.employees e where e.id = r.employee_id for update skip locked;
    if not found then
      continue;
    end if;
    if private.close_missed_checkout(r.employee_id, now()) then
      v_n := v_n + 1;
    elsif not (coalesce(v_on, false) and exists (select 1 from public.employee_work_schedules w where w.employee_id = r.employee_id)) then
      -- no window rule can judge this employee: 24 hours after the check-in
      select s.id, s.check_in_event_id into v_sess, v_ev from public.attendance_sessions s
      where s.employee_id = r.employee_id and s.status = 'open' order by s.created_at desc limit 1;
      select ev.occurred_at into v_in from public.attendance_events ev where ev.id = v_ev;
      if v_sess is not null and v_in <= now() - interval '24 hours' then
        update public.attendance_sessions set status = 'missed_checkout' where id = v_sess and status = 'open';
        if found then
          update public.attendance_events
             set needs_review = true, metadata = metadata || jsonb_build_object('missed_checkout', true)
           where id = v_ev;
          v_n := v_n + 1;
        end if;
      end if;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke all on function private.close_forgotten_sessions(uuid) from public, anon, authenticated;

-- The queue now also closes the forgotten sessions first, so it is no longer "stable" (it may write). Everything else is as in phase 15.
create or replace function public.admin_review_queue(p_limit integer default 200)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, event_type public.attendance_event_type,
  occurred_at timestamp with time zone, location_status text, suspect text[], biometric text, missed_checkout boolean,
  offline boolean, sync_delay_s integer, needs_review boolean, review_total bigint, leave jsonb)
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_tz text;
begin
  perform private.close_forgotten_sessions(v_company);
  select c.timezone into v_tz from public.companies c where c.id = v_company;
  return query
  select ev.id, ev.employee_id, emp.employee_number, emp.full_name, ev.event_type, ev.occurred_at, ev.location_status,
         coalesce(array(select jsonb_array_elements_text(ev.metadata -> 'suspect')), '{}'::text[]),
         ev.metadata ->> 'biometric',
         coalesce((ev.metadata ->> 'missed_checkout')::boolean, false),
         coalesce((ev.metadata ->> 'offline')::boolean, false),
         (ev.metadata ->> 'sync_delay_s')::integer,
         ev.needs_review,
         count(*) over (),
         case when ev.metadata ? 'leave_request_id' or cov.id is not null then
           (select jsonb_build_object('request_id', r.id, 'leave_type', r.leave_type, 'status', r.status, 'days', r.days,
                                      'start_date', (r.start_at at time zone c.timezone)::date,
                                      'end_date', ((r.end_at - interval '1 second') at time zone c.timezone)::date,
                                      -- the days of the leave the admin can cancel (his working days inside the range)
                                      'working_days', coalesce((
                                        select jsonb_agg(g::date order by g)
                                        from generate_series((r.start_at at time zone c.timezone)::date,
                                                             ((r.end_at - interval '1 second') at time zone c.timezone)::date, interval '1 day') as g
                                        where r.status = 'approved' and private.leave_days(r.employee_id, g::date, g::date) > 0), '[]'::jsonb))
            from public.requests r join public.companies c on c.id = r.company_id
            where r.id = coalesce((ev.metadata ->> 'leave_request_id')::uuid, cov.id) and r.company_id = v_company)
         end
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  -- the employee's own approved leave that covers the local day of the movement (a company holiday is not "his leave"): shown as a note on the row
  left join lateral (select r2.id from public.requests r2
                     where r2.id = private.approved_leave_on(ev.employee_id, (ev.occurred_at at time zone v_tz)::date)
                       and r2.company_leave_day_id is null) cov on true
  where ev.company_id = v_company and ev.needs_review
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 200), 1000), 1);
end;
$$;
revoke all on function public.admin_review_queue(integer) from public, anon;
grant execute on function public.admin_review_queue(integer) to authenticated;

-- ---------------------------------------------------------------- check-ins nobody made
-- Working days (last 7 local days, today included) with no movement, after shift start + grace. One row per employee and day.
-- No schedule = no shift start = no row. A shift that crosses midnight is left out (as phase 12 does for lateness).
create or replace function private.missing_checkins(p_company uuid, p_employee uuid default null)
returns table (employee_id uuid, employee_number text, full_name text, day date, shift_start timestamptz, grace_min integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_today date;
begin
  select c.timezone into v_tz from public.companies c where c.id = p_company;
  if v_tz is null then
    return;
  end if;
  v_today := (now() at time zone v_tz)::date;
  return query
  select e.id, e.employee_number, e.full_name, d.day, sb.shift_start, coalesce(e.late_grace_min, c.late_grace_min)::integer
  from public.employees e
  join public.companies c on c.id = e.company_id
  cross join lateral (select v_today - g as day from generate_series(0, 6) as g) d
  cross join lateral private.shift_bounds(e.id, d.day, v_tz) sb
  where e.company_id = p_company and (p_employee is null or e.id = p_employee)
    and e.is_active and e.deleted_at is null
    and sb.shift_end > sb.shift_start
    and d.day >= (e.created_at at time zone v_tz)::date
    and now() > sb.shift_start + make_interval(mins => coalesce(e.late_grace_min, c.late_grace_min)::integer)
    and not exists (select 1 from public.attendance_events x
                    where x.employee_id = e.id and (x.occurred_at at time zone v_tz)::date = d.day)
    and private.approved_leave_on(e.id, d.day) is null
    and private.holiday_on(p_company, d.day) is null
    and not exists (select 1 from public.attendance_day_decisions q where q.employee_id = e.id and q.day = d.day);
end;
$$;
revoke all on function private.missing_checkins(uuid, uuid) from public, anon, authenticated;

create or replace function public.admin_list_missing_checkins(p_limit integer default 200)
returns table (employee_id uuid, employee_number text, full_name text, day date, shift_start timestamptz, grace_min integer, missing_total bigint)
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select m.employee_id, m.employee_number, m.full_name, m.day, m.shift_start, m.grace_min, count(*) over ()
  from private.missing_checkins(v_company) m
  order by m.day desc, m.shift_start, m.full_name, m.employee_id
  limit greatest(least(coalesce(p_limit, 200), 1000), 1);
end;
$$;
revoke all on function public.admin_list_missing_checkins(integer) from public, anon;
grant execute on function public.admin_list_missing_checkins(integer) to authenticated;

-- "He did not come": the row leaves the list and the decision is kept (and audited). Only a day that is in the list can be decided.
create or replace function public.admin_dismiss_missing_checkin(p_employee_id uuid, p_day date, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_admin uuid := (select auth.uid());
  v_note text := left(nullif(trim(coalesce(p_note, '')), ''), 300);
begin
  if p_employee_id is null or p_day is null then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  -- Same lock as a punch (the employee first).
  perform 1 from public.employees e where e.id = p_employee_id and e.company_id = v_company for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.attendance_day_decisions q where q.employee_id = p_employee_id and q.day = p_day) then
    raise exception 'already_resolved' using errcode = 'P0001';
  end if;
  if not exists (select 1 from private.missing_checkins(v_company, p_employee_id) m where m.day = p_day) then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  insert into public.attendance_day_decisions (company_id, employee_id, day, decision, note, decided_by)
  values (v_company, p_employee_id, p_day, 'absent', v_note, v_admin);
  perform public.audit_write(v_company, 'attendance.day_absent', 'employee', p_employee_id::text,
    jsonb_build_object('day', p_day, 'note', v_note));
  return jsonb_build_object('employee_id', p_employee_id, 'day', p_day, 'decision', 'absent');
end;
$$;
revoke all on function public.admin_dismiss_missing_checkin(uuid, date, text) from public, anon;
grant execute on function public.admin_dismiss_missing_checkin(uuid, date, text) to authenticated;
