-- ============================================================================
-- Waqti Phase 4: employee requests + configurable approval chain (decided by Omar, 2026-10-30)
--
-- Decisions:
--   * Approval path is configurable PER COMPANY and per request type (up to 5 steps).
--     Step kinds: direct_manager, second_manager (manager of the manager), specific_employee, hr.
--     A company with no steps for a type uses the default: direct_manager -> hr.
--   * Managers approve inside the employee app; hr steps belong to company admins.
--   * Leave is deducted from the balance on final approval, and a request can never exceed the balance
--     (approved + pending are both counted).
--   * Permission (leave for some hours) is counted in minutes with a monthly limit per company.
--
-- Rules:
--   * Approvers are resolved and frozen when the request is submitted (a later manager change does not
--     reroute it). A step whose approver cannot be resolved, is the requester, is inactive, or repeats
--     the previous approver is SKIPPED. If no step remains, an hr step is added.
--   * Everything goes through security-definer functions; employees can only read their own rows.
-- ============================================================================

do $guard$
begin
  if to_regclass('public.companies') is null or to_regnamespace('private') is null then
    raise exception 'phases 2 and 3 must be applied first';
  end if;
  if to_regclass('public.approval_steps') is not null then
    raise exception 'phase 4 already applied';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- 1. Who is whose manager
alter table public.employees add column manager_id uuid;
alter table public.employees
  add constraint employees_manager_same_company
    foreign key (company_id, manager_id) references public.employees (company_id, id) on delete set null (manager_id),
  add constraint employees_manager_not_self check (manager_id is null or manager_id <> id);
create index employees_manager_idx on public.employees (manager_id) where manager_id is not null;

-- ---------------------------------------------------------------- 2. Company settings
alter table public.companies
  add column permission_minutes_per_month integer not null default 240
    check (permission_minutes_per_month between 0 and 20000);

-- ---------------------------------------------------------------- 3. Approval path per company and type
create table public.approval_steps (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  request_type public.request_type not null,
  step_order smallint not null check (step_order between 1 and 5),
  approver_kind text not null check (approver_kind in ('direct_manager', 'second_manager', 'specific_employee', 'hr')),
  approver_employee_id uuid,
  created_at timestamptz not null default now(),
  constraint approval_steps_specific_check check ((approver_kind = 'specific_employee') = (approver_employee_id is not null)),
  constraint approval_steps_order_key unique (company_id, request_type, step_order),
  constraint approval_steps_employee_same_company
    foreign key (company_id, approver_employee_id) references public.employees (company_id, id) on delete cascade
);

-- ---------------------------------------------------------------- 4. Requests: new columns, lock direct inserts
alter table public.requests
  add column leave_type text check (leave_type in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid')),
  add column days numeric(5,1),
  add column minutes integer check (minutes is null or minutes between 1 and 1440),
  add column request_key uuid,
  add column current_step smallint,
  add constraint requests_leave_type_required check ((request_type = 'leave') = (leave_type is not null)),
  add constraint requests_reason_length check (reason is null or length(reason) <= 500);
create unique index requests_key_uidx on public.requests (employee_id, request_key) where request_key is not null;
create index requests_employee_period_idx on public.requests (employee_id, start_at) where status in ('pending', 'approved');

-- Submissions must go through employee_submit_request (validation, balance, chain). No direct inserts.
drop policy if exists requests_insert_self on public.requests;
revoke insert, update, delete on public.requests from anon, authenticated;

-- ---------------------------------------------------------------- 5. One row per approval step of a request
create table public.request_approvals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  request_id uuid not null references public.requests (id) on delete cascade,
  step_order smallint not null,
  approver_kind text not null check (approver_kind in ('direct_manager', 'second_manager', 'specific_employee', 'hr')),
  approver_employee_id uuid references public.employees (id) on delete set null,
  status text not null default 'waiting'
    check (status in ('waiting', 'pending', 'approved', 'rejected', 'skipped', 'cancelled')),
  decided_by uuid references auth.users (id),
  decided_at timestamptz,
  note text check (note is null or length(note) <= 500),
  constraint request_approvals_step_key unique (request_id, step_order)
);
create index request_approvals_inbox_idx on public.request_approvals (approver_employee_id) where status = 'pending';
create index request_approvals_hr_idx on public.request_approvals (company_id) where status = 'pending' and approver_kind = 'hr';

alter table public.approval_steps enable row level security;
alter table public.request_approvals enable row level security;
revoke all on public.approval_steps, public.request_approvals from anon, authenticated;

-- ---------------------------------------------------------------- 6. Helpers (private: not callable through the API)
-- Working days of an employee between two dates (his weekly schedule; all days if he has no schedule).
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

-- Balance of one leave type in one year. entitled NULL = not limited.
create or replace function private.leave_balance(p_employee uuid, p_leave_type text, p_year int, p_exclude_request uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_emp public.employees;
  v_entitled numeric;
  v_used numeric;
  v_pending numeric;
begin
  select * into v_emp from public.employees where id = p_employee;
  select l.days into v_entitled from public.employee_leave_entitlements l
  where l.employee_id = p_employee and l.leave_type = p_leave_type;
  if v_entitled is null and p_leave_type = 'annual' then
    v_entitled := coalesce(
      public.default_annual_leave_days(v_emp.company_id, v_emp.birth_date),
      (select lp.days_below from public.leave_policy lp where lp.company_id = v_emp.company_id),
      30);
  end if;
  if p_leave_type = 'unpaid' then
    v_entitled := null;  -- never deducted, never limited
  end if;

  select coalesce(sum(r.days) filter (where r.status = 'approved'), 0),
         coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pending
  from public.requests r
  join public.companies c on c.id = r.company_id
  where r.employee_id = p_employee and r.request_type = 'leave' and r.leave_type = p_leave_type
    and extract(year from (r.start_at at time zone c.timezone)) = p_year
    and (p_exclude_request is null or r.id <> p_exclude_request);

  return jsonb_build_object(
    'leave_type', p_leave_type,
    'entitled', v_entitled,
    'used', v_used,
    'pending', v_pending,
    'remaining', case when v_entitled is null then null else v_entitled - v_used - v_pending end);
end;
$$;

-- Permission minutes in one calendar month (company time zone).
create or replace function private.permission_used(p_employee uuid, p_month_start date, p_exclude_request uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'month', to_char(p_month_start, 'YYYY-MM'),
    'limit', c.permission_minutes_per_month,
    'used', coalesce(sum(r.minutes) filter (where r.status = 'approved'), 0),
    'pending', coalesce(sum(r.minutes) filter (where r.status = 'pending'), 0))
  from public.employees e
  join public.companies c on c.id = e.company_id
  left join public.requests r
    on r.employee_id = e.id and r.request_type = 'permission' and r.status in ('approved', 'pending')
   and (r.start_at at time zone c.timezone)::date >= p_month_start
   and (r.start_at at time zone c.timezone)::date < (p_month_start + interval '1 month')::date
   and (p_exclude_request is null or r.id <> p_exclude_request)
  where e.id = p_employee
  group by c.permission_minutes_per_month
$$;

-- The path of a request type: the company's steps, or the default (direct_manager -> hr).
create or replace function private.request_chain(p_company uuid, p_type public.request_type)
returns table (step_order smallint, approver_kind text, approver_employee_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select s.step_order, s.approver_kind, s.approver_employee_id
  from public.approval_steps s
  where s.company_id = p_company and s.request_type = p_type
  union all
  select d.step_order, d.approver_kind, null::uuid
  from (values (1::smallint, 'direct_manager'), (2::smallint, 'hr')) as d (step_order, approver_kind)
  where not exists (select 1 from public.approval_steps s where s.company_id = p_company and s.request_type = p_type)
  order by 1
$$;

-- One request as the app shows it (with its steps). Used by the employee and the approver views.
create or replace function private.request_json(p_request uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'type', r.request_type, 'leave_type', r.leave_type, 'status', r.status,
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
  where r.id = p_request
$$;

-- Can the caller decide this approval step? (assigned employee, or a company admin for hr steps)
create or replace function private.can_decide(p_approval public.request_approvals, p_caller uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_approval.approver_kind = 'hr' then
      exists (select 1 from public.company_members m
              join public.employees e on e.id = m.user_id and e.is_active
              where m.user_id = p_caller and m.company_id = p_approval.company_id and m.role = 'company_admin')
    else p_approval.approver_employee_id = p_caller
  end
$$;

-- Moves a request after a decision on its current step. Shared by the approver and the admin.
create or replace function private.apply_decision(p_approval_id uuid, p_decision text, p_note text, p_actor uuid, p_override boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ap public.request_approvals;
  v_req public.requests;
  v_next public.request_approvals;
  v_bal jsonb;
  v_tz text;
begin
  if p_decision not in ('approve', 'reject') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_note is not null and length(p_note) > 500 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  select * into v_ap from public.request_approvals where id = p_approval_id for update;
  if not found then
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  select * into v_req from public.requests where id = v_ap.request_id for update;

  if v_req.employee_id = p_actor then
    raise exception 'cannot_decide_own' using errcode = '42501';
  end if;
  if v_ap.status <> 'pending' or v_req.status <> 'pending' then
    raise exception 'already_decided' using errcode = 'P0001';
  end if;

  if p_decision = 'reject' then
    update public.request_approvals
       set status = 'rejected', decided_by = p_actor, decided_at = now(), note = nullif(btrim(p_note), '')
     where id = v_ap.id;
    update public.request_approvals set status = 'cancelled' where request_id = v_req.id and status = 'waiting';
    update public.requests
       set status = 'rejected', decided_by = p_actor, decided_at = now(),
           decision_note = nullif(btrim(p_note), ''), current_step = null
     where id = v_req.id;
  else
    update public.request_approvals
       set status = 'approved', decided_by = p_actor, decided_at = now(), note = nullif(btrim(p_note), '')
     where id = v_ap.id;
    select * into v_next from public.request_approvals
     where request_id = v_req.id and status = 'waiting' order by step_order limit 1;
    if found then
      update public.request_approvals set status = 'pending' where id = v_next.id;
      update public.requests set current_step = v_next.step_order where id = v_req.id;
    else
      -- Final approval: the balance must still allow it (other requests may have been approved meanwhile).
      if v_req.request_type = 'leave' then
        select c.timezone into v_tz from public.companies c where c.id = v_req.company_id;
        v_bal := private.leave_balance(v_req.employee_id, v_req.leave_type,
                   extract(year from (v_req.start_at at time zone v_tz))::int, v_req.id);
        if (v_bal ->> 'entitled') is not null and (v_bal ->> 'entitled')::numeric - (v_bal ->> 'used')::numeric < v_req.days then
          raise exception 'insufficient_balance' using errcode = 'P0001';
        end if;
      end if;
      update public.requests
         set status = 'approved', decided_by = p_actor, decided_at = now(),
             decision_note = nullif(btrim(p_note), ''), current_step = null
       where id = v_req.id;
    end if;
  end if;

  perform public.audit_write(v_req.company_id,
    case when p_decision = 'approve' then 'request.approve' else 'request.reject' end,
    'request', v_req.id::text,
    jsonb_build_object('step', v_ap.step_order, 'kind', v_ap.approver_kind, 'override', p_override));

  return private.request_json(v_req.id);
end;
$$;

revoke all on function private.leave_days(uuid, date, date) from public, anon, authenticated;
revoke all on function private.leave_balance(uuid, text, int, uuid) from public, anon, authenticated;
revoke all on function private.permission_used(uuid, date, uuid) from public, anon, authenticated;
revoke all on function private.request_chain(uuid, public.request_type) from public, anon, authenticated;
revoke all on function private.request_json(uuid) from public, anon, authenticated;
revoke all on function private.can_decide(public.request_approvals, uuid) from public, anon, authenticated;
revoke all on function private.apply_decision(uuid, text, text, uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------- 7. Employee: overview, submit (with preview), cancel
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
    'permission', private.permission_used(me.employee_id, date_trunc('month', v_today)::date),
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

create or replace function public.employee_submit_request(
  p_request_key uuid,
  p_type text,
  p_leave_type text default null,
  p_start_date date default null,
  p_end_date date default null,
  p_start_at timestamptz default null,
  p_end_at timestamptz default null,
  p_reason text default null,
  p_dry_run boolean default false
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

  -- One lock per employee: two submissions are handled one after the other (balance stays correct).
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
    if p_start_at is null or p_end_at is null or p_end_at <= p_start_at
       or (p_start_at at time zone me.timezone)::date <> ((p_end_at - interval '1 second') at time zone me.timezone)::date then
      raise exception 'invalid_dates' using errcode = '22023';
    end if;
    v_minutes := ceil(extract(epoch from (p_end_at - p_start_at)) / 60)::int;
    if v_minutes < 15 or v_minutes > 480 then
      raise exception 'invalid_duration' using errcode = '22023';
    end if;
    if (p_start_at at time zone me.timezone)::date < v_today - 7 or (p_start_at at time zone me.timezone)::date > v_today + 90 then
      raise exception 'invalid_dates' using errcode = '22023';
    end if;
    v_perm := private.permission_used(me.employee_id, date_trunc('month', (p_start_at at time zone me.timezone))::date);
    if (v_perm ->> 'used')::int + (v_perm ->> 'pending')::int + v_minutes > (v_perm ->> 'limit')::int then
      raise exception 'permission_limit' using errcode = 'P0001';
    end if;
    v_start := p_start_at;
    v_end := p_end_at;

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
      'start_at', v_start, 'end_at', v_end, 'days', v_days, 'minutes', v_minutes,
      'balance', v_bal, 'permission', v_perm);
  end if;

  insert into public.requests (employee_id, request_type, leave_type, status, start_at, end_at, reason, days, minutes, request_key)
  values (me.employee_id, v_type, case when v_type = 'leave' then p_leave_type end, 'pending',
          v_start, v_end, v_reason, v_days, v_minutes, p_request_key)
  returning id into v_id;

  -- Resolve and freeze the approvers.
  for v_step in select * from private.request_chain(me.company_id, v_type) loop
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

create or replace function public.employee_cancel_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_req public.requests;
begin
  select * into me from public.require_active_employee();
  select * into v_req from public.requests where id = p_request_id and employee_id = me.employee_id for update;
  if not found then
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  if v_req.status = 'cancelled' then
    return private.request_json(v_req.id);
  end if;
  if v_req.status <> 'pending' then
    raise exception 'already_decided' using errcode = 'P0001';
  end if;
  update public.request_approvals set status = 'cancelled' where request_id = v_req.id and status in ('waiting', 'pending');
  update public.requests set status = 'cancelled', current_step = null where id = v_req.id;
  return private.request_json(v_req.id);
end;
$$;

-- ---------------------------------------------------------------- 8. Approver (in the employee app)
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
                 private.permission_used(r.employee_id, date_trunc('month', (r.start_at at time zone me.timezone))::date, r.id) end)
             order by r.created_at)
    from public.request_approvals a
    join public.requests r on r.id = a.request_id
    where a.status = 'pending' and r.status = 'pending'
      and a.company_id = me.company_id
      and r.employee_id <> me.employee_id
      and private.can_decide(a, me.employee_id)), '[]'::jsonb);
end;
$$;

create or replace function public.approver_decide(p_approval_id uuid, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_ap public.request_approvals;
begin
  select * into me from public.require_active_employee();
  select * into v_ap from public.request_approvals where id = p_approval_id;
  -- Not mine (or another company): looks exactly like "not found".
  if not found or v_ap.company_id <> me.company_id or not private.can_decide(v_ap, me.employee_id) then
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  return private.apply_decision(p_approval_id, p_decision, p_note, me.employee_id, false);
end;
$$;

-- ---------------------------------------------------------------- 9. Company admin (admin panel)
create or replace function public.admin_set_employee_manager(p_employee_id uuid, p_manager_id uuid)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_walk uuid := p_manager_id;
  v_depth int := 0;
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if p_manager_id is not null then
    if p_manager_id = p_employee_id then
      raise exception 'manager_cycle' using errcode = '22023';
    end if;
    if not exists (select 1 from public.employees where id = p_manager_id and company_id = v_company) then
      raise exception 'employee_not_found' using errcode = '22023';
    end if;
    -- The new manager may not be (directly or indirectly) managed by this employee.
    while v_walk is not null and v_depth < 50 loop
      if v_walk = p_employee_id then
        raise exception 'manager_cycle' using errcode = '22023';
      end if;
      select manager_id into v_walk from public.employees where id = v_walk;
      v_depth := v_depth + 1;
    end loop;
  end if;
  update public.employees set manager_id = p_manager_id where id = p_employee_id and company_id = v_company;
  perform public.audit_write(v_company, 'employee.set_manager', 'employee', p_employee_id::text,
    jsonb_build_object('manager_id', p_manager_id));
end;
$$;

-- Effective path per type (the company's steps, or the default).
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
    'permission_minutes_per_month', (select permission_minutes_per_month from public.companies where id = v_company),
    'chains', (
      select jsonb_object_agg(t, coalesce((
        select jsonb_agg(jsonb_build_object('step_order', c.step_order, 'kind', c.approver_kind,
                 'approver_employee_id', c.approver_employee_id,
                 'approver_name', (select e.full_name from public.employees e where e.id = c.approver_employee_id))
               order by c.step_order)
        from private.request_chain(v_company, t::public.request_type) c), '[]'::jsonb))
      from unnest(array['leave', 'permission', 'other']) as t),
    'customized', (
      select coalesce(jsonb_agg(distinct s.request_type), '[]'::jsonb) from public.approval_steps s where s.company_id = v_company));
end;
$$;

-- p_steps: [{"kind": "direct_manager"}, {"kind": "specific_employee", "approver_employee_id": "..."}, {"kind": "hr"}]
-- An empty array goes back to the default path. Requests already submitted keep their frozen path.
create or replace function public.admin_set_approval_chain(p_request_type text, p_steps jsonb)
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
     or jsonb_typeof(p_steps) is distinct from 'array' or jsonb_array_length(p_steps) > 5 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  delete from public.approval_steps where company_id = v_company and request_type = p_request_type::public.request_type;
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
    insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id)
    values (v_company, p_request_type::public.request_type, v_order, v_kind, v_emp);
  end loop;
  perform public.audit_write(v_company, 'approval_chain.set', 'company', v_company::text,
    jsonb_build_object('request_type', p_request_type, 'steps', p_steps));
exception
  when invalid_text_representation then
    raise exception 'invalid_input' using errcode = '22023';
end;
$$;

create or replace function public.admin_set_request_settings(p_permission_minutes_per_month integer)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_permission_minutes_per_month is null or p_permission_minutes_per_month not between 0 and 20000 then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.companies set permission_minutes_per_month = p_permission_minutes_per_month where id = v_company;
  perform public.audit_write(v_company, 'company.request_settings', 'company', v_company::text,
    jsonb_build_object('permission_minutes_per_month', p_permission_minutes_per_month));
end;
$$;

create or replace function public.admin_list_requests(
  p_status text default null, p_type text default null, p_employee_id uuid default null,
  p_limit integer default 50, p_offset integer default 0
)
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
    'total', (select count(*) from public.requests r
              where r.company_id = v_company
                and (p_status is null or r.status::text = p_status)
                and (p_type is null or r.request_type::text = p_type)
                and (p_employee_id is null or r.employee_id = p_employee_id)),
    'items', coalesce((
      select jsonb_agg(private.request_json(x.id) order by x.created_at desc)
      from (select r.id, r.created_at from public.requests r
            where r.company_id = v_company
              and (p_status is null or r.status::text = p_status)
              and (p_type is null or r.request_type::text = p_type)
              and (p_employee_id is null or r.employee_id = p_employee_id)
            order by r.created_at desc
            limit greatest(least(coalesce(p_limit, 50), 500), 1) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb));
end;
$$;

-- The admin decides the CURRENT step of any pending request of the company (hr step, or override when
-- an approver is unavailable). Overrides are marked in the audit log.
create or replace function public.admin_decide_request(p_request_id uuid, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_ap public.request_approvals;
begin
  select a.* into v_ap from public.request_approvals a
  join public.requests r on r.id = a.request_id
  where a.request_id = p_request_id and r.company_id = v_company and a.status = 'pending';
  if not found then
    if exists (select 1 from public.requests where id = p_request_id and company_id = v_company) then
      raise exception 'already_decided' using errcode = 'P0001';
    end if;
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  return private.apply_decision(v_ap.id, p_decision, p_note, auth.uid(), v_ap.approver_kind <> 'hr');
end;
$$;

-- ---------------------------------------------------------------- 10. Grants
do $g$
declare f text;
begin
  foreach f in array array[
    'public.employee_requests_overview()',
    'public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean)',
    'public.employee_cancel_request(uuid)',
    'public.approver_inbox()',
    'public.approver_decide(uuid, text, text)',
    'public.admin_set_employee_manager(uuid, uuid)',
    'public.admin_get_approval_chains()',
    'public.admin_set_approval_chain(text, jsonb)',
    'public.admin_set_request_settings(integer)',
    'public.admin_list_requests(text, text, uuid, integer, integer)',
    'public.admin_decide_request(uuid, text, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$g$;
