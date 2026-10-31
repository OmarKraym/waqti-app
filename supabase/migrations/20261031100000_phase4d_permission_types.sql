-- ============================================================================
-- Waqti Phase 4d: permission TYPES, set by each company (decided by Omar, 2026-10-31).
--
-- Decisions:
--   * Each company keeps its own list of permission types (add, edit, deactivate in the admin panel).
--     Per type: name, how its time is entered (mode), max requests per month, max minutes per request,
--     how many days back / ahead it may be requested.
--       mode 'range'        : the employee enters from-to (exit during the shift, work mission)
--       mode 'late_arrival' : the employee enters his arrival time; it starts at his shift start
--       mode 'early_leave'  : the employee enters his exit time; it ends at his shift end (final exit)
--   * Every permission goes through the approval path, and each type has its OWN path
--     (approval_steps.permission_type_id). Without a custom path: direct manager -> HR.
--   * The general monthly limit in hours (companies.permission_minutes_per_month) is removed;
--     only the per-type limits apply.
--   * Pending + approved requests count toward the monthly limits (as for leave balances).
--   * Defaults for every company (existing and new):
--       خروج أثناء الدوام   range         3 / month, 120 min max, 7 days back, 30 ahead
--       خروج نهائي من الدوام early_leave   1 / month, no time max, 7 days back, 30 ahead
--       تبرير تأخير          late_arrival  3 / month,  60 min max, same day only (0 back, 0 ahead)
--       مهمة عمل            range         no limit,  no time max, 7 days back, 30 ahead
--   * The company's current general permission path is copied to each default type.
-- ============================================================================

do $guard$
begin
  if to_regclass('public.approval_steps') is null then
    raise exception 'phase 4 must be applied first';
  end if;
  if to_regclass('public.permission_types') is not null then
    raise exception 'phase 4d already applied';
  end if;
  if exists (select 1 from public.requests where request_type = 'permission') then
    raise exception 'permission requests exist: migrate them to a type first';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- 1. The types
create table public.permission_types (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 60),
  mode text not null check (mode in ('range', 'late_arrival', 'early_leave')),
  max_per_month smallint check (max_per_month is null or max_per_month between 1 and 100),
  max_minutes smallint check (max_minutes is null or max_minutes between 1 and 1440),
  days_back smallint not null default 7 check (days_back between 0 and 60),
  days_ahead smallint not null default 30 check (days_ahead between 0 and 365),
  is_active boolean not null default true,
  sort_order smallint not null default 0,
  created_at timestamptz not null default now(),
  constraint permission_types_company_id_key unique (company_id, id)
);
create unique index permission_types_name_uidx on public.permission_types (company_id, lower(btrim(name)));
alter table public.permission_types enable row level security;
revoke all on public.permission_types from anon, authenticated;

-- ---------------------------------------------------------------- 2. Requests and paths know their type
alter table public.requests
  add column permission_type_id uuid,
  add constraint requests_permission_type_same_company
    foreign key (company_id, permission_type_id) references public.permission_types (company_id, id),
  add constraint requests_permission_type_required check ((request_type = 'permission') = (permission_type_id is not null));
create index requests_permission_type_idx on public.requests (employee_id, permission_type_id, start_at)
  where permission_type_id is not null and status in ('pending', 'approved');

alter table public.approval_steps
  add column permission_type_id uuid,
  add constraint approval_steps_permission_type_same_company
    foreign key (company_id, permission_type_id) references public.permission_types (company_id, id) on delete cascade,
  add constraint approval_steps_permission_type_required check ((request_type = 'permission') = (permission_type_id is not null)),
  drop constraint approval_steps_order_key;
create unique index approval_steps_order_uidx on public.approval_steps
  (company_id, request_type, coalesce(permission_type_id, '00000000-0000-0000-0000-000000000000'::uuid), step_order);

-- ---------------------------------------------------------------- 3. Defaults (existing companies + every new one)
create or replace function private.seed_permission_types(p_company uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.permission_types (company_id, name, mode, max_per_month, max_minutes, days_back, days_ahead, sort_order)
  values (p_company, 'خروج أثناء الدوام', 'range', 3, 120, 7, 30, 1),
         (p_company, 'خروج نهائي من الدوام', 'early_leave', 1, null, 7, 30, 2),
         (p_company, 'تبرير تأخير', 'late_arrival', 3, 60, 0, 0, 3),
         (p_company, 'مهمة عمل', 'range', null, null, 7, 30, 4)
$$;
revoke all on function private.seed_permission_types(uuid) from public, anon, authenticated;

create or replace function private.companies_seed_permission_types()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.seed_permission_types(new.id);
  return new;
end;
$$;
revoke all on function private.companies_seed_permission_types() from public, anon, authenticated;
create trigger companies_seed_permission_types after insert on public.companies
  for each row execute function private.companies_seed_permission_types();

do $seed$ begin perform private.seed_permission_types(c.id) from public.companies c; end $seed$;

-- The general permission path (if a company had one) becomes the path of each default type.
insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id, permission_type_id)
select s.company_id, s.request_type, s.step_order, s.approver_kind, s.approver_employee_id, t.id
from public.approval_steps s
join public.permission_types t on t.company_id = s.company_id
where s.request_type = 'permission' and s.permission_type_id is null;
delete from public.approval_steps where request_type = 'permission' and permission_type_id is null;

-- ---------------------------------------------------------------- 4. Remove the general monthly limit
drop function public.admin_set_request_settings(integer);
drop function private.permission_used(uuid, date, uuid);
-- (companies.permission_minutes_per_month is dropped at the end, after the functions that read it are replaced)

-- ---------------------------------------------------------------- 5. Helpers
-- The employee's shift on a day (company time zone), or nothing if it is not a workday.
create or replace function private.shift_bounds(p_employee uuid, p_day date, p_tz text)
returns table (shift_start timestamptz, shift_end timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select (p_day + w.start_time) at time zone p_tz, (p_day + w.end_time) at time zone p_tz
  from public.employee_work_schedules w
  where w.employee_id = p_employee and w.weekday = extract(dow from p_day)::int and w.is_workday
$$;
revoke all on function private.shift_bounds(uuid, date, text) from public, anon, authenticated;

-- How much of one permission type an employee used in a calendar month (pending + approved count).
create or replace function private.permission_usage(p_employee uuid, p_type uuid, p_month_start date, p_exclude_request uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', t.id, 'name', t.name, 'mode', t.mode,
    'max_per_month', t.max_per_month, 'max_minutes', t.max_minutes,
    'days_back', t.days_back, 'days_ahead', t.days_ahead,
    'month', to_char(p_month_start, 'YYYY-MM'),
    'used', (select count(*) from public.requests r
             where r.employee_id = p_employee and r.permission_type_id = t.id and r.status = 'approved'
               and (r.start_at at time zone c.timezone)::date >= p_month_start
               and (r.start_at at time zone c.timezone)::date < (p_month_start + interval '1 month')::date
               and (p_exclude_request is null or r.id <> p_exclude_request)),
    'pending', (select count(*) from public.requests r
                where r.employee_id = p_employee and r.permission_type_id = t.id and r.status = 'pending'
                  and (r.start_at at time zone c.timezone)::date >= p_month_start
                  and (r.start_at at time zone c.timezone)::date < (p_month_start + interval '1 month')::date
                  and (p_exclude_request is null or r.id <> p_exclude_request)))
  from public.permission_types t
  join public.companies c on c.id = t.company_id
  where t.id = p_type
$$;
revoke all on function private.permission_usage(uuid, uuid, date, uuid) from public, anon, authenticated;

-- The path of a request type (and permission type): the company's steps, or direct manager -> HR.
drop function private.request_chain(uuid, public.request_type);
create or replace function private.request_chain(p_company uuid, p_type public.request_type, p_permission_type uuid default null)
returns table (step_order smallint, approver_kind text, approver_employee_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select s.step_order, s.approver_kind, s.approver_employee_id
  from public.approval_steps s
  where s.company_id = p_company and s.request_type = p_type and s.permission_type_id is not distinct from p_permission_type
  union all
  select d.step_order, d.approver_kind, null::uuid
  from (values (1::smallint, 'direct_manager'), (2::smallint, 'hr')) as d (step_order, approver_kind)
  where not exists (select 1 from public.approval_steps s
                    where s.company_id = p_company and s.request_type = p_type
                      and s.permission_type_id is not distinct from p_permission_type)
  order by 1
$$;
revoke all on function private.request_chain(uuid, public.request_type, uuid) from public, anon, authenticated;

-- One request as the app shows it: now with the permission type name.
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
    'start_at', r.start_at, 'end_at', r.end_at, 'days', r.days, 'minutes', r.minutes,
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

-- ---------------------------------------------------------------- 6. Employee
create or replace function public.employee_requests_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_today date;
  v_emp public.employees;
begin
  select * into me from public.require_active_employee();
  select * into v_emp from public.employees where id = me.employee_id;
  v_today := (now() at time zone me.timezone)::date;

  return jsonb_build_object(
    'balances', (
      select jsonb_agg(private.leave_balance(me.employee_id, t, extract(year from v_today)::int) order by o)
      from unnest(array['annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid']) with ordinality as x (t, o)
      where t <> 'maternity' or v_emp.gender = 'female'),
    'permission_types', coalesce((
      select jsonb_agg(private.permission_usage(me.employee_id, pt.id, date_trunc('month', v_today)::date) order by pt.sort_order, pt.name)
      from public.permission_types pt
      where pt.company_id = me.company_id and pt.is_active), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(private.request_json(r.id) order by r.created_at desc)
      from (select id, created_at from public.requests where employee_id = me.employee_id
            order by created_at desc limit 30) r), '[]'::jsonb),
    'inbox_count', (
      select count(*) from public.request_approvals a
      where a.status = 'pending'
        and a.company_id = me.company_id
        and private.can_decide(a, me.employee_id)
        and not exists (select 1 from public.requests r where r.id = a.request_id and r.employee_id = me.employee_id)),
    'timezone', me.timezone,
    'today', v_today);
end;
$$;

drop function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean);
create or replace function public.employee_submit_request(
  p_request_key uuid,
  p_type text,
  p_leave_type text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_start_at timestamptz default null,
  p_end_at timestamptz default null,
  p_reason text default null,
  p_dry_run boolean default false,
  p_permission_type_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_emp public.employees;
  v_today date;
  v_type public.request_type;
  v_start timestamptz;
  v_end timestamptz;
  v_days numeric;
  v_minutes int;
  v_bal jsonb;
  v_perm jsonb;
  v_pt public.permission_types;
  v_day date;
  v_shift_start timestamptz;
  v_shift_end timestamptz;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_id uuid;
  v_step record;
  v_approver uuid;
  v_prev uuid;
  v_kept int := 0;
  v_first smallint;
  v_status text;
begin
  select * into me from public.require_active_employee();
  select * into v_emp from public.employees where id = me.employee_id;
  v_today := (now() at time zone me.timezone)::date;

  if p_request_key is null or p_type is null or p_type not in ('leave', 'permission', 'other') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  v_type := p_type::public.request_type;
  if v_reason is not null and length(v_reason) > 500 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  -- Same key again (double tap, retry after a lost reply): return the saved request.
  if not p_dry_run then
    select id into v_id from public.requests where employee_id = me.employee_id and request_key = p_request_key;
    if found then
      return private.request_json(v_id) || jsonb_build_object('duplicate', true);
    end if;
  end if;

  -- One lock per employee: two submissions are handled one after the other (limits stay correct).
  perform 1 from public.employees where id = me.employee_id for update;

  if v_type = 'leave' then
    if p_leave_type is null or p_leave_type not in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid')
       or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
      raise exception 'invalid_dates' using errcode = '22023';
    end if;
    if p_end_date - p_start_date > 365 or p_start_date < v_today - 30 or p_start_date > v_today + 365 then
      raise exception 'invalid_dates' using errcode = '22023';
    end if;
    if extract(year from p_start_date) <> extract(year from p_end_date) then
      raise exception 'crosses_year' using errcode = 'P0001';
    end if;
    if p_leave_type = 'maternity' and coalesce(v_emp.gender, '') <> 'female' then
      raise exception 'maternity_female_only' using errcode = '22023';
    end if;
    v_days := private.leave_days(me.employee_id, p_start_date, p_end_date);
    if v_days = 0 then
      raise exception 'no_working_days' using errcode = 'P0001';
    end if;
    v_bal := private.leave_balance(me.employee_id, p_leave_type, extract(year from p_start_date)::int);
    if (v_bal ->> 'remaining') is not null and (v_bal ->> 'remaining')::numeric < v_days then
      raise exception 'insufficient_balance' using errcode = 'P0001';
    end if;
    v_start := p_start_date::timestamp at time zone me.timezone;
    v_end := (p_end_date + 1)::timestamp at time zone me.timezone;  -- exclusive end

  elsif v_type = 'permission' then
    select * into v_pt from public.permission_types
    where id = p_permission_type_id and company_id = me.company_id and is_active;
    if not found then
      raise exception 'permission_type_not_found' using errcode = '22023';
    end if;

    if v_pt.mode = 'range' then
      if p_start_at is null or p_end_at is null or p_end_at <= p_start_at
         or (p_start_at at time zone me.timezone)::date <> ((p_end_at - interval '1 second') at time zone me.timezone)::date then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      v_start := p_start_at;
      v_end := p_end_at;
      v_day := (p_start_at at time zone me.timezone)::date;
    elsif v_pt.mode = 'late_arrival' then
      -- The employee gives his arrival time; the permission starts at his shift start.
      if p_end_at is null then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      v_day := (p_end_at at time zone me.timezone)::date;
      select s.shift_start, s.shift_end into v_shift_start, v_shift_end from private.shift_bounds(me.employee_id, v_day, me.timezone) s;
      if v_shift_start is null then
        raise exception 'no_working_days' using errcode = 'P0001';
      end if;
      if p_end_at <= v_shift_start then
        raise exception 'not_late' using errcode = '22023';
      end if;
      if p_end_at > v_shift_end then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      v_start := v_shift_start;
      v_end := p_end_at;
    else -- early_leave
      -- The employee gives his exit time; the permission ends at his shift end.
      if p_start_at is null then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      v_day := (p_start_at at time zone me.timezone)::date;
      select s.shift_start, s.shift_end into v_shift_start, v_shift_end from private.shift_bounds(me.employee_id, v_day, me.timezone) s;
      if v_shift_start is null then
        raise exception 'no_working_days' using errcode = 'P0001';
      end if;
      if p_start_at >= v_shift_end or p_start_at < v_shift_start then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      v_start := p_start_at;
      v_end := v_shift_end;
    end if;

    v_minutes := ceil(extract(epoch from (v_end - v_start)) / 60)::int;
    if v_minutes < 1 or v_minutes > 1440 then
      raise exception 'invalid_duration' using errcode = '22023';
    end if;
    if v_pt.max_minutes is not null and v_minutes > v_pt.max_minutes then
      raise exception 'permission_too_long' using errcode = 'P0001';
    end if;
    if v_day < v_today - v_pt.days_back or v_day > v_today + v_pt.days_ahead then
      raise exception 'outside_window' using errcode = 'P0001';
    end if;
    v_perm := private.permission_usage(me.employee_id, v_pt.id, date_trunc('month', v_day)::date);
    if v_pt.max_per_month is not null
       and (v_perm ->> 'used')::int + (v_perm ->> 'pending')::int >= v_pt.max_per_month then
      raise exception 'permission_limit' using errcode = 'P0001';
    end if;

  else -- other
    if v_reason is null then
      raise exception 'reason_required' using errcode = '22023';
    end if;
    if p_start_date is null or p_end_date is null or p_end_date < p_start_date
       or p_end_date - p_start_date > 365 or p_start_date < v_today - 30 or p_start_date > v_today + 365 then
      raise exception 'invalid_dates' using errcode = '22023';
    end if;
    v_start := p_start_date::timestamp at time zone me.timezone;
    v_end := (p_end_date + 1)::timestamp at time zone me.timezone;
  end if;

  -- No overlap with my own pending/approved leave or permission.
  if v_type in ('leave', 'permission') and exists (
       select 1 from public.requests r
       where r.employee_id = me.employee_id and r.status in ('pending', 'approved')
         and r.request_type in ('leave', 'permission')
         and tstzrange(r.start_at, r.end_at, '[)') && tstzrange(v_start, v_end, '[)')) then
    raise exception 'overlapping_request' using errcode = 'P0001';
  end if;

  if p_dry_run then
    return jsonb_build_object('dry_run', true, 'type', v_type, 'leave_type', p_leave_type,
      'permission_type_id', v_pt.id, 'start_at', v_start, 'end_at', v_end, 'days', v_days, 'minutes', v_minutes,
      'balance', v_bal, 'permission', v_perm);
  end if;

  insert into public.requests (employee_id, request_type, leave_type, permission_type_id, status, start_at, end_at,
                               reason, days, minutes, request_key)
  values (me.employee_id, v_type, case when v_type = 'leave' then p_leave_type end, v_pt.id, 'pending',
          v_start, v_end, v_reason, v_days, v_minutes, p_request_key)
  returning id into v_id;

  -- Resolve and freeze the approvers.
  for v_step in select * from private.request_chain(me.company_id, v_type, v_pt.id) loop
    v_approver := case v_step.approver_kind
      when 'direct_manager' then v_emp.manager_id
      when 'second_manager' then (select m.manager_id from public.employees m where m.id = v_emp.manager_id)
      when 'specific_employee' then v_step.approver_employee_id
      else null end;
    if v_step.approver_kind <> 'hr' and (
         v_approver is null
         or v_approver = me.employee_id
         or not exists (select 1 from public.employees a where a.id = v_approver and a.is_active and a.company_id = me.company_id)
         or v_approver is not distinct from v_prev) then
      v_status := 'skipped';
    else
      v_status := 'waiting';
      v_kept := v_kept + 1;
      v_prev := v_approver;
    end if;
    insert into public.request_approvals (company_id, request_id, step_order, approver_kind, approver_employee_id, status)
    values (me.company_id, v_id, v_step.step_order, v_step.approver_kind, v_approver, v_status);
  end loop;

  if v_kept = 0 then
    insert into public.request_approvals (company_id, request_id, step_order, approver_kind, status)
    values (me.company_id, v_id,
            coalesce((select max(step_order) from public.request_approvals where request_id = v_id), 0) + 1,
            'hr', 'waiting');
  end if;

  select min(step_order) into v_first from public.request_approvals where request_id = v_id and status = 'waiting';
  update public.request_approvals set status = 'pending' where request_id = v_id and step_order = v_first;
  update public.requests set current_step = v_first where id = v_id;

  return private.request_json(v_id) || jsonb_build_object('duplicate', false);
exception
  when unique_violation then
    -- Two identical submissions at the same instant: the other one won; return it.
    select id into v_id from public.requests where employee_id = me.employee_id and request_key = p_request_key;
    if v_id is null then raise; end if;
    return private.request_json(v_id) || jsonb_build_object('duplicate', true);
end;
$$;

-- ---------------------------------------------------------------- 7. Approver inbox: the requester's use of that permission type
create or replace function public.approver_inbox()
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
  return coalesce((
    select jsonb_agg(
             private.request_json(r.id) || jsonb_build_object(
               'approval_id', a.id,
               'my_step', a.step_order,
               'step_count', (select count(*) from public.request_approvals x where x.request_id = r.id and x.status <> 'skipped'),
               'balance', case when r.request_type = 'leave' then
                 private.leave_balance(r.employee_id, r.leave_type, extract(year from (r.start_at at time zone me.timezone))::int, r.id) end,
               'permission', case when r.request_type = 'permission' then
                 private.permission_usage(r.employee_id, r.permission_type_id, date_trunc('month', (r.start_at at time zone me.timezone))::date, r.id) end)
             order by r.created_at)
    from public.request_approvals a
    join public.requests r on r.id = a.request_id
    where a.status = 'pending' and r.status = 'pending'
      and a.company_id = me.company_id
      and r.employee_id <> me.employee_id
      and private.can_decide(a, me.employee_id)), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- 8. Admin: the types
create or replace function public.admin_list_permission_types()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'name', t.name, 'mode', t.mode, 'max_per_month', t.max_per_month, 'max_minutes', t.max_minutes,
             'days_back', t.days_back, 'days_ahead', t.days_ahead, 'is_active', t.is_active, 'sort_order', t.sort_order,
             'requests_count', (select count(*) from public.requests r where r.permission_type_id = t.id))
           order by t.sort_order, t.name)
    from public.permission_types t where t.company_id = v_company), '[]'::jsonb);
end;
$$;

-- p_id null = new type. Types are never deleted (old requests keep their type): deactivate instead.
create or replace function public.admin_save_permission_type(
  p_id uuid, p_name text, p_mode text, p_max_per_month integer, p_max_minutes integer,
  p_days_back integer, p_days_ahead integer, p_is_active boolean, p_sort_order integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
begin
  if length(v_name) not between 1 and 60 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_mode is null or p_mode not in ('range', 'late_arrival', 'early_leave')
     or (p_max_per_month is not null and p_max_per_month not between 1 and 100)
     or (p_max_minutes is not null and p_max_minutes not between 1 and 1440)
     or p_days_back is null or p_days_back not between 0 and 60
     or p_days_ahead is null or p_days_ahead not between 0 and 365
     or p_is_active is null or coalesce(p_sort_order, 0) not between 0 and 1000 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if exists (select 1 from public.permission_types
             where company_id = v_company and lower(btrim(name)) = lower(v_name) and id is distinct from p_id) then
    raise exception 'name_exists' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.permission_types (company_id, name, mode, max_per_month, max_minutes, days_back, days_ahead, is_active, sort_order)
    values (v_company, v_name, p_mode, p_max_per_month, p_max_minutes, p_days_back, p_days_ahead, p_is_active, coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    update public.permission_types
       set name = v_name, mode = p_mode, max_per_month = p_max_per_month, max_minutes = p_max_minutes,
           days_back = p_days_back, days_ahead = p_days_ahead, is_active = p_is_active, sort_order = coalesce(p_sort_order, 0)
     where id = p_id and company_id = v_company
    returning id into v_id;
    if v_id is null then
      raise exception 'permission_type_not_found' using errcode = '22023';
    end if;
  end if;

  perform public.audit_write(v_company, case when p_id is null then 'permission_type.create' else 'permission_type.update' end,
    'permission_type', v_id::text,
    jsonb_build_object('name', v_name, 'mode', p_mode, 'max_per_month', p_max_per_month, 'max_minutes', p_max_minutes,
                       'days_back', p_days_back, 'days_ahead', p_days_ahead, 'is_active', p_is_active));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------- 9. Admin: paths (one per permission type)
create or replace function public.admin_get_approval_chains()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return jsonb_build_object(
    'chains', (
      select jsonb_object_agg(t, coalesce((
        select jsonb_agg(jsonb_build_object('step_order', c.step_order, 'kind', c.approver_kind,
                 'approver_employee_id', c.approver_employee_id,
                 'approver_name', (select e.full_name from public.employees e where e.id = c.approver_employee_id))
               order by c.step_order)
        from private.request_chain(v_company, t::public.request_type) c), '[]'::jsonb))
      from unnest(array['leave', 'other']) as t),
    'customized', (
      select coalesce(jsonb_agg(distinct s.request_type), '[]'::jsonb)
      from public.approval_steps s where s.company_id = v_company and s.request_type <> 'permission'),
    'permission_types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pt.id, 'name', pt.name, 'is_active', pt.is_active,
               'customized', exists (select 1 from public.approval_steps s where s.permission_type_id = pt.id),
               'steps', coalesce((
                 select jsonb_agg(jsonb_build_object('step_order', c.step_order, 'kind', c.approver_kind,
                          'approver_employee_id', c.approver_employee_id,
                          'approver_name', (select e.full_name from public.employees e where e.id = c.approver_employee_id))
                        order by c.step_order)
                 from private.request_chain(v_company, 'permission', pt.id) c), '[]'::jsonb))
             order by pt.sort_order, pt.name)
      from public.permission_types pt where pt.company_id = v_company), '[]'::jsonb));
end;
$$;

drop function public.admin_set_approval_chain(text, jsonb);
-- p_steps: [{"kind": "direct_manager"}, {"kind": "specific_employee", "approver_employee_id": "..."}, {"kind": "hr"}]
-- An empty array goes back to the default path. Requests already submitted keep their frozen path.
-- For 'permission', p_permission_type_id says which type; for 'leave' and 'other' it must be null.
create or replace function public.admin_set_approval_chain(p_request_type text, p_steps jsonb, p_permission_type_id uuid default null)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_item jsonb;
  v_order smallint := 0;
  v_kind text;
  v_emp uuid;
begin
  if p_request_type is null or p_request_type not in ('leave', 'permission', 'other')
     or jsonb_typeof(p_steps) is distinct from 'array' or jsonb_array_length(p_steps) > 5
     or (p_request_type = 'permission') <> (p_permission_type_id is not null) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_permission_type_id is not null
     and not exists (select 1 from public.permission_types where id = p_permission_type_id and company_id = v_company) then
    raise exception 'permission_type_not_found' using errcode = '22023';
  end if;
  delete from public.approval_steps
   where company_id = v_company and request_type = p_request_type::public.request_type
     and permission_type_id is not distinct from p_permission_type_id;
  for v_item in select * from jsonb_array_elements(p_steps) loop
    v_order := v_order + 1;
    v_kind := v_item ->> 'kind';
    v_emp := nullif(v_item ->> 'approver_employee_id', '')::uuid;
    if v_kind is null or v_kind not in ('direct_manager', 'second_manager', 'specific_employee', 'hr') then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    if v_kind <> 'specific_employee' then
      v_emp := null;
    elsif v_emp is null or not exists (select 1 from public.employees where id = v_emp and company_id = v_company and is_active) then
      raise exception 'employee_not_found' using errcode = '22023';
    end if;
    insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id, permission_type_id)
    values (v_company, p_request_type::public.request_type, v_order, v_kind, v_emp, p_permission_type_id);
  end loop;
  perform public.audit_write(v_company, 'approval_chain.set', 'company', v_company::text,
    jsonb_build_object('request_type', p_request_type, 'permission_type_id', p_permission_type_id, 'steps', p_steps));
exception
  when invalid_text_representation then
    raise exception 'invalid_input' using errcode = '22023';
end;
$$;

-- ---------------------------------------------------------------- 10. Drop the general limit column, grants
alter table public.companies drop column permission_minutes_per_month;

do $g$
declare f text;
begin
  foreach f in array array[
    'public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid)',
    'public.admin_list_permission_types()',
    'public.admin_save_permission_type(uuid, text, text, integer, integer, integer, integer, boolean, integer)',
    'public.admin_set_approval_chain(text, jsonb, uuid)',
    'public.employee_requests_overview()',
    'public.approver_inbox()',
    'public.admin_get_approval_chains()'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$g$;
