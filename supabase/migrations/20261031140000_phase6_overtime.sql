-- ============================================================================
-- Waqti Phase 6: overtime assignments (decided by Omar, 2026-10-31).
--
--   * Who assigns: the employee's direct manager or anyone above him in the manager chain.
--   * An assignment is binding at once (no approval). The employee is notified and can write a note when he
--     cannot do it (the assigner is notified); the assignment stays until the assigner (or anyone above the
--     employee) cancels it, which is possible until it starts.
--   * When: outside the employee's shift only (before it, after it, or on his day off), never on an approved
--     leave day/time or overlapping an approved/pending permission or another assignment. One calendar day per
--     assignment (company time zone), from now (15 min grace) up to 60 days ahead.
--   * Limits per company (admin panel): max minutes per employee per day and per month (null = no limit).
--     Active assignments count toward the limits (cancelled ones do not).
--   * Actual time: the part of the assignment window covered by the employee's attendance sessions
--     (check-in .. check-out; an open session counts until now).
-- ============================================================================

do $guard$
begin
  if to_regclass('public.notifications') is null then
    raise exception 'phase 5 must be applied first';
  end if;
  if to_regclass('public.overtime_assignments') is not null then
    raise exception 'phase 6 already applied';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- 1. Limits and the table
alter table public.companies
  add column overtime_max_day_minutes smallint check (overtime_max_day_minutes is null or overtime_max_day_minutes between 15 and 1440),
  add column overtime_max_month_minutes integer check (overtime_max_month_minutes is null or overtime_max_month_minutes between 15 and 44640);

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('approval_needed', 'request_decided', 'reminder_check_in', 'reminder_check_out', 'test',
                  'overtime_assigned', 'overtime_cancelled', 'overtime_note'));

create table public.overtime_assignments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  employee_id uuid not null,
  assigned_by uuid not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  minutes integer not null check (minutes between 15 and 1440),
  task text check (task is null or length(task) <= 500),
  status text not null default 'assigned' check (status in ('assigned', 'cancelled')),
  employee_note text check (employee_note is null or length(employee_note) <= 500),
  employee_noted_at timestamptz,
  cancelled_by uuid references public.employees (id) on delete set null,
  cancelled_at timestamptz,
  assign_key uuid not null,
  created_at timestamptz not null default now(),
  constraint overtime_period_valid check (end_at > start_at),
  constraint overtime_employee_same_company foreign key (company_id, employee_id) references public.employees (company_id, id) on delete cascade,
  constraint overtime_assigner_same_company foreign key (company_id, assigned_by) references public.employees (company_id, id) on delete cascade,
  constraint overtime_assign_key unique (assigned_by, assign_key)
);
create index overtime_employee_time_idx on public.overtime_assignments (employee_id, start_at) where status = 'assigned';
create index overtime_company_time_idx on public.overtime_assignments (company_id, start_at);
create index overtime_assigner_idx on public.overtime_assignments (assigned_by, created_at desc);
alter table public.overtime_assignments enable row level security;
revoke all on public.overtime_assignments from anon, authenticated;

-- ---------------------------------------------------------------- 2. Helpers
-- Is p_manager above p_employee in the manager chain (direct manager, his manager, ...)?
create or replace function private.manages(p_manager uuid, p_employee uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_walk uuid;
  v_depth int := 0;
begin
  select manager_id into v_walk from public.employees where id = p_employee;
  while v_walk is not null and v_depth < 50 loop
    if v_walk = p_manager then
      return true;
    end if;
    select manager_id into v_walk from public.employees where id = v_walk;
    v_depth := v_depth + 1;
  end loop;
  return false;
end;
$$;
revoke all on function private.manages(uuid, uuid) from public, anon, authenticated;

-- Minutes of the assignment window actually covered by attendance (check-in .. check-out, open = now).
create or replace function private.overtime_actual(p_employee uuid, p_start timestamptz, p_end timestamptz)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(floor(sum(extract(epoch from (least(p_end, coalesce(eo.occurred_at, now())) - greatest(p_start, ei.occurred_at)))) / 60), 0)::int
  from public.attendance_sessions s
  join public.attendance_events ei on ei.id = s.check_in_event_id
  left join public.attendance_events eo on eo.id = s.check_out_event_id
  where s.employee_id = p_employee
    and ei.occurred_at < p_end
    and coalesce(eo.occurred_at, now()) > p_start
    and least(p_end, coalesce(eo.occurred_at, now())) > greatest(p_start, ei.occurred_at)
$$;
revoke all on function private.overtime_actual(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- Assigned minutes of an employee on a day / in a month (active assignments only; one may be excluded).
create or replace function private.overtime_used(p_employee uuid, p_day date, p_tz text, p_exclude uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'day', coalesce(sum(o.minutes) filter (where (o.start_at at time zone p_tz)::date = p_day), 0),
    'month', coalesce(sum(o.minutes) filter (where date_trunc('month', o.start_at at time zone p_tz) = date_trunc('month', p_day::timestamp)), 0))
  from public.overtime_assignments o
  where o.employee_id = p_employee and o.status = 'assigned' and (p_exclude is null or o.id <> p_exclude)
    and (o.start_at at time zone p_tz)::date >= date_trunc('month', p_day::timestamp)::date
    and (o.start_at at time zone p_tz)::date < (date_trunc('month', p_day::timestamp) + interval '1 month')::date
$$;
revoke all on function private.overtime_used(uuid, date, text, uuid) from public, anon, authenticated;

create or replace function private.overtime_json(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', o.id, 'status', o.status, 'start_at', o.start_at, 'end_at', o.end_at, 'minutes', o.minutes, 'task', o.task,
    'employee', jsonb_build_object('id', e.id, 'full_name', e.full_name, 'employee_number', e.employee_number, 'department', e.department),
    'assigned_by', jsonb_build_object('id', a.id, 'full_name', a.full_name),
    'employee_note', o.employee_note, 'employee_noted_at', o.employee_noted_at,
    'cancelled_at', o.cancelled_at, 'cancelled_by_name', cb.full_name, 'created_at', o.created_at,
    'actual_minutes', case when o.status = 'assigned' and o.start_at < now() then private.overtime_actual(o.employee_id, o.start_at, o.end_at) end,
    'phase', case when o.status = 'cancelled' then 'cancelled' when now() < o.start_at then 'upcoming'
                  when now() < o.end_at then 'now' else 'done' end)
  from public.overtime_assignments o
  join public.employees e on e.id = o.employee_id
  join public.employees a on a.id = o.assigned_by
  left join public.employees cb on cb.id = o.cancelled_by
  where o.id = p_id
$$;
revoke all on function private.overtime_json(uuid) from public, anon, authenticated;

-- "31/10 18:00–20:00"
create or replace function private.overtime_when(p_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select to_char(o.start_at at time zone c.timezone, 'DD/MM HH24:MI') || '–' || to_char(o.end_at at time zone c.timezone, 'HH24:MI')
  from public.overtime_assignments o join public.companies c on c.id = o.company_id where o.id = p_id
$$;
revoke all on function private.overtime_when(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. Employee app
-- Mine (upcoming + last 60 days), my team (people I may assign), what I assigned, and the limits.
create or replace function public.employee_overtime_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  me record;
begin
  select * into me from public.require_active_employee();
  return jsonb_build_object(
    'mine', coalesce((
      select jsonb_agg(private.overtime_json(o.id) order by o.start_at desc)
      from public.overtime_assignments o
      where o.employee_id = me.employee_id and o.end_at > now() - interval '60 days'), '[]'::jsonb),
    'team', coalesce((
      with recursive down as (
        select e.id, 1 as depth from public.employees e where e.manager_id = me.employee_id
        union all
        select e.id, d.depth + 1 from public.employees e join down d on e.manager_id = d.id where d.depth < 50)
      select jsonb_agg(jsonb_build_object('id', e.id, 'full_name', e.full_name, 'employee_number', e.employee_number,
                                          'department', e.department, 'direct', e.manager_id = me.employee_id)
                       order by (e.manager_id = me.employee_id) desc, e.full_name)
      from public.employees e where e.id in (select id from down) and e.is_active), '[]'::jsonb),
    'assigned_by_me', coalesce((
      select jsonb_agg(private.overtime_json(x.id) order by x.start_at desc)
      from (select o.id, o.start_at from public.overtime_assignments o
            where o.assigned_by = me.employee_id and o.end_at > now() - interval '60 days'
            order by o.start_at desc limit 50) x), '[]'::jsonb),
    'limits', (select jsonb_build_object('day_minutes', c.overtime_max_day_minutes, 'month_minutes', c.overtime_max_month_minutes)
               from public.companies c where c.id = me.company_id),
    'timezone', me.timezone,
    'today', (now() at time zone me.timezone)::date);
end;
$$;

create or replace function public.manager_assign_overtime(
  p_assign_key uuid, p_employee_id uuid, p_start_at timestamptz, p_end_at timestamptz, p_task text default null, p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_emp public.employees;
  v_co public.companies;
  v_day date;
  v_minutes int;
  v_used jsonb;
  v_task text := nullif(btrim(coalesce(p_task, '')), '');
  v_id uuid;
  v_shift_start timestamptz;
  v_shift_end timestamptz;
begin
  select * into me from public.require_active_employee();
  if p_assign_key is null or p_employee_id is null or (v_task is not null and length(v_task) > 500) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  if not p_dry_run then
    select id into v_id from public.overtime_assignments where assigned_by = me.employee_id and assign_key = p_assign_key;
    if found then
      return private.overtime_json(v_id) || jsonb_build_object('duplicate', true);
    end if;
  end if;

  select * into v_emp from public.employees where id = p_employee_id and company_id = me.company_id and is_active;
  if not found or not private.manages(me.employee_id, p_employee_id) then
    raise exception 'not_your_team' using errcode = '42501';
  end if;
  select * into v_co from public.companies where id = me.company_id;

  -- one lock per employee: two assignments at once still respect the limits
  perform 1 from public.employees where id = p_employee_id for update;

  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at
     or (p_start_at at time zone me.timezone)::date <> ((p_end_at - interval '1 second') at time zone me.timezone)::date then
    raise exception 'invalid_dates' using errcode = '22023';
  end if;
  v_day := (p_start_at at time zone me.timezone)::date;
  if p_start_at < now() - interval '15 minutes' or v_day > (now() at time zone me.timezone)::date + 60 then
    raise exception 'invalid_dates' using errcode = '22023';
  end if;
  v_minutes := ceil(extract(epoch from (p_end_at - p_start_at)) / 60)::int;
  if v_minutes < 15 then
    raise exception 'invalid_duration' using errcode = '22023';
  end if;

  -- outside his shift only
  select s.shift_start, s.shift_end into v_shift_start, v_shift_end from private.shift_bounds(p_employee_id, v_day, me.timezone) s;
  if v_shift_start is not null and tstzrange(p_start_at, p_end_at, '[)') && tstzrange(v_shift_start, v_shift_end, '[)') then
    raise exception 'overlaps_shift' using errcode = 'P0001';
  end if;
  -- not on approved leave, not over a permission, not over another assignment
  if exists (select 1 from public.requests r
             where r.employee_id = p_employee_id and r.request_type = 'leave' and r.status = 'approved'
               and tstzrange(r.start_at, r.end_at, '[)') && tstzrange(p_start_at, p_end_at, '[)')) then
    raise exception 'on_leave' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.requests r
             where r.employee_id = p_employee_id and r.request_type = 'permission' and r.status in ('pending', 'approved')
               and tstzrange(r.start_at, r.end_at, '[)') && tstzrange(p_start_at, p_end_at, '[)'))
     or exists (select 1 from public.overtime_assignments o
                where o.employee_id = p_employee_id and o.status = 'assigned'
                  and tstzrange(o.start_at, o.end_at, '[)') && tstzrange(p_start_at, p_end_at, '[)')) then
    raise exception 'overlapping_overtime' using errcode = 'P0001';
  end if;

  v_used := private.overtime_used(p_employee_id, v_day, me.timezone);
  if v_co.overtime_max_day_minutes is not null and (v_used ->> 'day')::int + v_minutes > v_co.overtime_max_day_minutes then
    raise exception 'overtime_day_limit' using errcode = 'P0001';
  end if;
  if v_co.overtime_max_month_minutes is not null and (v_used ->> 'month')::int + v_minutes > v_co.overtime_max_month_minutes then
    raise exception 'overtime_month_limit' using errcode = 'P0001';
  end if;

  if p_dry_run then
    return jsonb_build_object('dry_run', true, 'minutes', v_minutes, 'start_at', p_start_at, 'end_at', p_end_at,
      'used_day', (v_used ->> 'day')::int, 'used_month', (v_used ->> 'month')::int,
      'limit_day', v_co.overtime_max_day_minutes, 'limit_month', v_co.overtime_max_month_minutes,
      'shift_start', v_shift_start, 'shift_end', v_shift_end);
  end if;

  insert into public.overtime_assignments (company_id, employee_id, assigned_by, start_at, end_at, minutes, task, assign_key)
  values (me.company_id, p_employee_id, me.employee_id, p_start_at, p_end_at, v_minutes, v_task, p_assign_key)
  returning id into v_id;

  perform private.notify(p_employee_id, me.company_id, 'overtime_assigned', 'تكليف بعمل إضافي',
    private.overtime_when(v_id) || ' · من ' || me.full_name || coalesce(E'\n' || v_task, ''),
    '?tab=requests', 'overtime-' || v_id::text, 86400 * 7);
  perform public.audit_write(me.company_id, 'overtime.assign', 'overtime', v_id::text,
    jsonb_build_object('employee_id', p_employee_id, 'start_at', p_start_at, 'end_at', p_end_at, 'minutes', v_minutes));
  return private.overtime_json(v_id) || jsonb_build_object('duplicate', false);
exception
  when unique_violation then
    select id into v_id from public.overtime_assignments where assigned_by = me.employee_id and assign_key = p_assign_key;
    if v_id is null then raise; end if;
    return private.overtime_json(v_id) || jsonb_build_object('duplicate', true);
end;
$$;

-- The assigner, or anyone above the employee, cancels before it starts.
create or replace function public.manager_cancel_overtime(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_o public.overtime_assignments;
begin
  select * into me from public.require_active_employee();
  select * into v_o from public.overtime_assignments where id = p_id and company_id = me.company_id for update;
  if not found or not (v_o.assigned_by = me.employee_id or private.manages(me.employee_id, v_o.employee_id)) then
    raise exception 'overtime_not_found' using errcode = '22023';
  end if;
  if v_o.status = 'cancelled' then
    return private.overtime_json(v_o.id);
  end if;
  if now() >= v_o.start_at then
    raise exception 'overtime_started' using errcode = 'P0001';
  end if;
  update public.overtime_assignments set status = 'cancelled', cancelled_by = me.employee_id, cancelled_at = now() where id = v_o.id;
  perform private.notify(v_o.employee_id, me.company_id, 'overtime_cancelled', 'أُلغي تكليف العمل الإضافي',
    private.overtime_when(v_o.id) || ' · ألغاه ' || me.full_name, '?tab=requests', 'overtime-' || v_o.id::text, 86400 * 3);
  perform public.audit_write(me.company_id, 'overtime.cancel', 'overtime', v_o.id::text, '{}'::jsonb);
  return private.overtime_json(v_o.id);
end;
$$;

-- The employee writes (or changes) a note, e.g. that he cannot do it. The assigner is notified.
create or replace function public.employee_overtime_note(p_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_o public.overtime_assignments;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into me from public.require_active_employee();
  if v_note is null or length(v_note) > 500 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_o from public.overtime_assignments where id = p_id and employee_id = me.employee_id for update;
  if not found then
    raise exception 'overtime_not_found' using errcode = '22023';
  end if;
  if v_o.status = 'cancelled' or now() >= v_o.end_at then
    raise exception 'overtime_closed' using errcode = 'P0001';
  end if;
  update public.overtime_assignments set employee_note = v_note, employee_noted_at = now() where id = v_o.id;
  perform private.notify(v_o.assigned_by, me.company_id, 'overtime_note', 'ملاحظة على تكليف عمل إضافي',
    me.full_name || ' · ' || private.overtime_when(v_o.id) || E'\n' || v_note, '?tab=requests', 'overtime-note-' || v_o.id::text, 86400 * 3);
  return private.overtime_json(v_o.id);
end;
$$;

-- ---------------------------------------------------------------- 4. Admin panel
create or replace function public.admin_get_overtime_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return (select jsonb_build_object('day_minutes', overtime_max_day_minutes, 'month_minutes', overtime_max_month_minutes)
          from public.companies where id = v_company);
end;
$$;

create or replace function public.admin_set_overtime_settings(p_day_minutes integer, p_month_minutes integer)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if (p_day_minutes is not null and p_day_minutes not between 15 and 1440)
     or (p_month_minutes is not null and p_month_minutes not between 15 and 44640)
     or (p_day_minutes is not null and p_month_minutes is not null and p_month_minutes < p_day_minutes) then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.companies set overtime_max_day_minutes = p_day_minutes, overtime_max_month_minutes = p_month_minutes where id = v_company;
  perform public.audit_write(v_company, 'company.overtime_settings', 'company', v_company::text,
    jsonb_build_object('day_minutes', p_day_minutes, 'month_minutes', p_month_minutes));
end;
$$;

-- All assignments of a month (YYYY-MM-01), with the actual time; optionally one employee.
create or replace function public.admin_list_overtime(p_month date default null, p_employee_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_tz text;
  v_month date;
begin
  select timezone into v_tz from public.companies where id = v_company;
  v_month := date_trunc('month', coalesce(p_month, (now() at time zone v_tz)::date))::date;
  return jsonb_build_object(
    'month', to_char(v_month, 'YYYY-MM'),
    'items', coalesce((
      select jsonb_agg(private.overtime_json(o.id) order by o.start_at desc)
      from public.overtime_assignments o
      where o.company_id = v_company
        and (o.start_at at time zone v_tz)::date >= v_month and (o.start_at at time zone v_tz)::date < (v_month + interval '1 month')::date
        and (p_employee_id is null or o.employee_id = p_employee_id)), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------- 5. Grants
do $g$
declare f text;
begin
  foreach f in array array[
    'public.employee_overtime_overview()',
    'public.manager_assign_overtime(uuid, uuid, timestamptz, timestamptz, text, boolean)',
    'public.manager_cancel_overtime(uuid)',
    'public.employee_overtime_note(uuid, text)',
    'public.admin_get_overtime_settings()',
    'public.admin_set_overtime_settings(integer, integer)',
    'public.admin_list_overtime(date, uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$g$;
