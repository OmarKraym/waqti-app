-- ROLLBACK for 20261031100000_phase4d_permission_types.sql
-- Restores phase 4 permissions: one general monthly limit in minutes (default 240) and one path for all permissions.
-- DATA LOSS: permission types are deleted; permission requests lose their type (the requests themselves stay).
-- The general permission path is rebuilt from the path of the first permission type of each company.

do $guard$
begin
  if to_regclass('public.permission_types') is null then
    raise exception 'phase 4d is not applied';
  end if;
end
$guard$;

drop function if exists public.admin_list_permission_types();
drop function if exists public.admin_save_permission_type(uuid, text, text, integer, integer, integer, integer, boolean, integer);
drop function if exists public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid);
drop function if exists public.admin_set_approval_chain(text, jsonb, uuid);
drop function if exists private.request_chain(uuid, public.request_type, uuid);
drop function if exists private.permission_usage(uuid, uuid, date, uuid);
drop function if exists private.shift_bounds(uuid, date, text);
drop trigger if exists companies_seed_permission_types on public.companies;
drop function if exists private.companies_seed_permission_types();
drop function if exists private.seed_permission_types(uuid);

alter table public.companies
  add column permission_minutes_per_month integer not null default 240
    check (permission_minutes_per_month between 0 and 20000);

-- one general permission path per company, from its first type's custom path (if any)
insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id, permission_type_id)
select s.company_id, s.request_type, s.step_order, s.approver_kind, s.approver_employee_id, null
from public.approval_steps s
join lateral (select t.id from public.permission_types t where t.company_id = s.company_id
              and exists (select 1 from public.approval_steps x where x.permission_type_id = t.id)
              order by t.sort_order, t.name limit 1) f on f.id = s.permission_type_id;
delete from public.approval_steps where permission_type_id is not null;
drop index if exists public.approval_steps_order_uidx;
alter table public.approval_steps
  drop constraint if exists approval_steps_permission_type_required,
  drop constraint if exists approval_steps_permission_type_same_company,
  drop column permission_type_id,
  add constraint approval_steps_order_key unique (company_id, request_type, step_order);

drop index if exists public.requests_permission_type_idx;
alter table public.requests
  drop constraint if exists requests_permission_type_required,
  drop constraint if exists requests_permission_type_same_company,
  drop column permission_type_id;
drop table public.permission_types;

-- functions exactly as in phase 4

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

revoke all on function private.permission_used(uuid, date, uuid) from public, anon, authenticated;
revoke all on function private.request_chain(uuid, public.request_type) from public, anon, authenticated;
do $g$
declare f text;
begin
  foreach f in array array[
    'public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean)',
    'public.admin_set_approval_chain(text, jsonb)',
    'public.admin_set_request_settings(integer)'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$g$;
