-- Phase 19b: late deduction policies.
--   * public.deduction_policies: per company, dated (effective_from), kind 'proportional' or 'tiers'.
--       proportional: every `per_minutes` chargeable late minutes = `deduct_minutes` of pay, rounded (up / down / nearest) to a
--                     step of `round_to` minutes.
--       tiers:        [{from, to, deduct}], from >= 1, no gap or overlap, only the last tier may be open (to = null).
--     The deduction is in MINUTES OF PAY (turning minutes into money belongs to payroll).
--   * private.deduction_calc is the ONLY place where the formula lives. The policy in force on a day is the one with the
--     greatest effective_from <= that day (private.late_deduction); a day before the first policy deducts nothing.
--   * A policy can be edited or deleted only while effective_from >= the company's today. Older ones are history.
--   * admin_preview_deduction shows what a policy would deduct for given minutes after the shift start, using the
--     company's grace and late rule (phase 19a), so the panel never recomputes anything.
-- Nothing here blocks a punch. Rollback: 20261108110000_phase19b_deduction_policies_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('private.chargeable_minutes(integer, integer, text)') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regprocedure('public.require_company_admin()') is null then
    raise exception 'phase19b: run phase 19a first (late rule)';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- table
create table public.deduction_policies (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  effective_from date not null,
  kind text not null check (kind in ('proportional', 'tiers')),
  params jsonb not null check (jsonb_typeof(params) = 'object'),
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint deduction_policies_company_date_key unique (company_id, effective_from)
);
alter table public.deduction_policies enable row level security;
revoke all on public.deduction_policies from anon, authenticated;

-- ---------------------------------------------------------------- validation and calculation (pure)
-- An integer JSON number inside [p_min, p_max], else null.
create or replace function private.json_int(p jsonb, p_min integer, p_max integer)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  v numeric;
begin
  if p is null or jsonb_typeof(p) <> 'number' then return null; end if;
  v := (p #>> '{}')::numeric;
  if v <> trunc(v) or v < p_min or v > p_max then return null; end if;
  return v::integer;
end;
$$;
revoke all on function private.json_int(jsonb, integer, integer) from public, anon, authenticated;

-- The policy parameters in their clean form (only the known keys, integers), or null when they are not valid.
create or replace function private.deduction_params_clean(p_kind text, p_params jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_per integer; v_ded integer; v_round integer; v_rounding text;
  t jsonb; v_from integer; v_to integer; v_d integer; v_prev_to integer;
  v_tiers jsonb := '[]'::jsonb; v_open boolean := false; v_n integer;
begin
  if p_params is null or jsonb_typeof(p_params) <> 'object' then return null; end if;
  if p_kind = 'proportional' then
    v_per := private.json_int(p_params -> 'per_minutes', 1, 240);
    v_ded := private.json_int(p_params -> 'deduct_minutes', 0, 1440);
    v_round := private.json_int(p_params -> 'round_to', 1, 60);
    if jsonb_typeof(p_params -> 'rounding') is distinct from 'string' then return null; end if;
    v_rounding := p_params ->> 'rounding';
    if v_per is null or v_ded is null or v_round is null or v_round not in (1, 5, 10, 15, 30, 60)
       or v_rounding not in ('up', 'down', 'nearest') then
      return null;
    end if;
    return jsonb_build_object('per_minutes', v_per, 'deduct_minutes', v_ded, 'round_to', v_round, 'rounding', v_rounding);
  elsif p_kind = 'tiers' then
    if jsonb_typeof(p_params -> 'tiers') is distinct from 'array' then return null; end if;
    v_n := jsonb_array_length(p_params -> 'tiers');
    if v_n < 1 or v_n > 50 then return null; end if;
    for t in select value from jsonb_array_elements(p_params -> 'tiers') loop
      if jsonb_typeof(t) <> 'object' or v_open then return null; end if;   -- an open tier must be the last one
      v_from := private.json_int(t -> 'from', 1, 100000);
      v_d := private.json_int(t -> 'deduct', 0, 1440);
      if v_from is null or v_d is null then return null; end if;
      if coalesce(jsonb_typeof(t -> 'to'), 'null') = 'null' then
        v_to := null;
        v_open := true;
      else
        v_to := private.json_int(t -> 'to', 1, 100000);
        if v_to is null or v_to < v_from then return null; end if;
      end if;
      if v_prev_to is not null and v_from <> v_prev_to + 1 then return null; end if;   -- a gap or an overlap
      v_tiers := v_tiers || jsonb_build_array(jsonb_build_object('from', v_from, 'to', v_to, 'deduct', v_d));
      v_prev_to := v_to;
    end loop;
    return jsonb_build_object('tiers', v_tiers);
  end if;
  return null;
end;
$$;
revoke all on function private.deduction_params_clean(text, jsonb) from public, anon, authenticated;

create or replace function private.deduction_params_ok(p_kind text, p_params jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$ select private.deduction_params_clean(p_kind, p_params) is not null $$;
revoke all on function private.deduction_params_ok(text, jsonb) from public, anon, authenticated;

-- Minutes of pay to deduct for `p_chargeable` late minutes under one (clean) policy. THE formula.
create or replace function private.deduction_calc(p_kind text, p_params jsonb, p_chargeable integer)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
declare
  v numeric;
  v_step numeric;
  t jsonb;
begin
  if p_chargeable is null or p_chargeable <= 0 then return 0; end if;
  if p_kind = 'proportional' then
    v_step := (p_params ->> 'round_to')::numeric;
    v := p_chargeable::numeric * (p_params ->> 'deduct_minutes')::numeric / ((p_params ->> 'per_minutes')::numeric * v_step);
    v := case p_params ->> 'rounding' when 'up' then ceil(v) when 'down' then floor(v) else round(v) end;
    return (v * v_step)::integer;
  elsif p_kind = 'tiers' then
    for t in select value from jsonb_array_elements(p_params -> 'tiers') loop
      if p_chargeable >= (t ->> 'from')::integer
         and (coalesce(jsonb_typeof(t -> 'to'), 'null') = 'null' or p_chargeable <= (t ->> 'to')::integer) then
        return (t ->> 'deduct')::integer;
      end if;
    end loop;
  end if;
  return 0;
end;
$$;
revoke all on function private.deduction_calc(text, jsonb, integer) from public, anon, authenticated;

-- The deduction of a company on a local day: the policy with the greatest effective_from <= that day, else 0.
create or replace function private.late_deduction(p_company uuid, p_day date, p_chargeable integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select private.deduction_calc(p.kind, p.params, p_chargeable)
                   from public.deduction_policies p
                   where p.company_id = p_company and p.effective_from <= p_day
                   order by p.effective_from desc limit 1), 0)
$$;
revoke all on function private.late_deduction(uuid, date, integer) from public, anon, authenticated;

create or replace function private.deduction_policy_json(p public.deduction_policies, p_today date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('id', p.id, 'effective_from', p.effective_from, 'kind', p.kind, 'params', p.params,
                            'editable', p.effective_from >= p_today, 'created_at', p.created_at)
$$;
revoke all on function private.deduction_policy_json(public.deduction_policies, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_list_deduction_policies()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_today date;
begin
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  return coalesce((select jsonb_agg(private.deduction_policy_json(p, v_today) order by p.effective_from desc)
                   from public.deduction_policies p where p.company_id = v_company), '[]'::jsonb);
end;
$$;

-- p_id null = a new policy. Only a policy that has not started yet (effective_from >= today) can be created or changed.
create or replace function public.admin_save_deduction_policy(p_id uuid, p_effective_from date, p_kind text, p_params jsonb)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_today date;
  v_params jsonb;
  v_old public.deduction_policies;
  v_row public.deduction_policies;
begin
  if p_effective_from is null or p_kind is null or p_kind not in ('proportional', 'tiers') then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  v_params := private.deduction_params_clean(p_kind, p_params);
  if v_params is null then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('waqti.deduction:' || v_company::text, 0));
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  if p_effective_from < v_today then
    raise exception 'policy_locked' using errcode = 'P0001';
  end if;
  if p_id is not null then
    select * into v_old from public.deduction_policies where id = p_id and company_id = v_company;
    if not found then
      raise exception 'policy_not_found' using errcode = '22023';
    end if;
    if v_old.effective_from < v_today then
      raise exception 'policy_locked' using errcode = 'P0001';
    end if;
  end if;
  if exists (select 1 from public.deduction_policies x
             where x.company_id = v_company and x.effective_from = p_effective_from and x.id is distinct from p_id) then
    raise exception 'policy_date_taken' using errcode = 'P0001';
  end if;
  if p_id is null then
    insert into public.deduction_policies (company_id, effective_from, kind, params, created_by)
    values (v_company, p_effective_from, p_kind, v_params, auth.uid()) returning * into v_row;
  else
    update public.deduction_policies set effective_from = p_effective_from, kind = p_kind, params = v_params
    where id = p_id and company_id = v_company returning * into v_row;
  end if;
  perform public.audit_write(v_company, 'company.deduction_policy', 'deduction_policy', v_row.id::text,
    jsonb_build_object('effective_from', v_row.effective_from, 'kind', v_row.kind, 'params', v_row.params, 'new', p_id is null));
  return private.deduction_policy_json(v_row, v_today);
end;
$$;

create or replace function public.admin_delete_deduction_policy(p_id uuid)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_today date;
  v_old public.deduction_policies;
begin
  perform pg_advisory_xact_lock(hashtextextended('waqti.deduction:' || v_company::text, 0));
  select (now() at time zone c.timezone)::date into v_today from public.companies c where c.id = v_company;
  select * into v_old from public.deduction_policies where id = p_id and company_id = v_company;
  if not found then
    raise exception 'policy_not_found' using errcode = '22023';
  end if;
  if v_old.effective_from < v_today then
    raise exception 'policy_locked' using errcode = 'P0001';
  end if;
  delete from public.deduction_policies where id = p_id and company_id = v_company;
  perform public.audit_write(v_company, 'company.deduction_policy_delete', 'deduction_policy', p_id::text,
    jsonb_build_object('effective_from', v_old.effective_from, 'kind', v_old.kind, 'params', v_old.params));
end;
$$;

-- p_policy = {"kind": ..., "params": ...}; p_late_after_start = minutes after the shift start (0..1440, at most 50 values).
-- Returns [{late, chargeable, deduct}] using THIS company's grace and late rule.
create or replace function public.admin_preview_deduction(p_policy jsonb, p_late_after_start integer[])
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_kind text;
  v_params jsonb;
  v_grace integer;
  v_rule text;
  v_out jsonb := '[]'::jsonb;
  x integer;
  v_ch integer;
begin
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' or jsonb_typeof(p_policy -> 'kind') is distinct from 'string' then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  v_kind := p_policy ->> 'kind';
  v_params := private.deduction_params_clean(v_kind, p_policy -> 'params');
  if v_params is null or p_late_after_start is null or cardinality(p_late_after_start) not between 1 and 50 then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  select c.late_grace_min, c.late_rule into v_grace, v_rule from public.companies c where c.id = v_company;
  foreach x in array p_late_after_start loop
    if x is null or x not between 0 and 1440 then
      raise exception 'invalid_settings' using errcode = '22023';
    end if;
    v_ch := private.chargeable_minutes(x, v_grace, v_rule);
    v_out := v_out || jsonb_build_array(jsonb_build_object('late', x, 'chargeable', v_ch, 'deduct', private.deduction_calc(v_kind, v_params, v_ch)));
  end loop;
  return v_out;
end;
$$;

do $grants$
declare f text;
begin
  foreach f in array array[
    'public.admin_list_deduction_policies()',
    'public.admin_save_deduction_policy(uuid, date, text, jsonb)',
    'public.admin_delete_deduction_policy(uuid)',
    'public.admin_preview_deduction(jsonb, integer[])'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$grants$;

-- ---------------------------------------------------------------- the deduction of one punch
-- {"minutes": n, "state": ...} for the employee's FIRST check-in of a local day, or null (not a check-in of this employee,
-- not the first arrival, a day off). state:
--   none    : nothing to deduct (on time, within the grace, no policy, or the policy deducts 0 for these minutes)
--   excused : an APPROVED late-arrival justification covers the arrival (its end >= the arrival minute: the employee
--             enters hours and minutes, so the seconds of the punch are ignored); minutes = 0
--   pending : a deduction applies and a justification that covers it is still waiting for a decision; minutes = provisional
--   due     : a deduction applies and nothing excuses it
-- A justification that stops before the real arrival, a rejected or cancelled one, another permission type, or somebody
-- else's never excuses anything.
create or replace function private.punch_deduction(p_employee uuid, p_event uuid, p_at timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid;
  v_tz text;
  v_day date;
  v_ch integer;
  v_amount integer;
begin
  select e.company_id, c.timezone into v_company, v_tz
  from public.attendance_events ev
  join public.employees e on e.id = ev.employee_id
  join public.companies c on c.id = e.company_id
  where ev.id = p_event and ev.employee_id = p_employee and ev.event_type = 'check_in';
  if not found then return null; end if;
  v_ch := private.punch_lateness(p_employee, p_event, 'check_in', p_at);
  if v_ch is null then return null; end if;
  if v_ch = 0 then return jsonb_build_object('minutes', 0, 'state', 'none'); end if;
  v_day := (p_at at time zone v_tz)::date;
  if exists (select 1 from public.requests r
             join public.permission_types pt on pt.id = r.permission_type_id and pt.mode = 'late_arrival'
             where r.employee_id = p_employee and r.request_type = 'permission' and r.status = 'approved'
               and (r.start_at at time zone v_tz)::date = v_day and r.end_at >= date_trunc('minute', p_at)) then
    return jsonb_build_object('minutes', 0, 'state', 'excused');
  end if;
  v_amount := private.late_deduction(v_company, v_day, v_ch);
  if v_amount = 0 then return jsonb_build_object('minutes', 0, 'state', 'none'); end if;
  return jsonb_build_object('minutes', v_amount,
    'state', case when exists (select 1 from public.requests r
                               join public.permission_types pt on pt.id = r.permission_type_id and pt.mode = 'late_arrival'
                               where r.employee_id = p_employee and r.request_type = 'permission' and r.status = 'pending'
                                 and (r.start_at at time zone v_tz)::date = v_day and r.end_at >= date_trunc('minute', p_at))
                  then 'pending' else 'due' end);
end;
$$;
revoke all on function private.punch_deduction(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- attendance list: + deduction_minutes, deduction_state
-- (phase 12 text with two more columns at the end; null for check-outs and for punches that are not a first arrival)
do $guard2$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'admin_list_attendance'
                   and pg_get_function_result(p.oid) like '%late_minutes integer, early_minutes integer)') then
    raise exception 'phase19b: admin_list_attendance is not the phase 12 version';
  end if;
end
$guard2$;

drop function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer);
create function public.admin_list_attendance(p_from timestamp with time zone default null, p_to timestamp with time zone default null,
  p_employee_id uuid default null, p_event_type public.attendance_event_type default null, p_limit integer default 50, p_offset integer default 0)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, email text, department text,
  event_type public.attendance_event_type, occurred_at timestamp with time zone, received_at timestamp with time zone,
  within_geofence boolean, geofence_enforced boolean, geofence_name text, distance_meters numeric, accuracy_meters numeric,
  latitude double precision, longitude double precision, authentication_method text, device_id text, total_count bigint,
  needs_review boolean, location_status text, source text, offline boolean, sync_delay_s integer, suspect text[],
  biometric text, missed_checkout boolean, late_minutes integer, early_minutes integer,
  deduction_minutes integer, deduction_state text)
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    ev.id, ev.employee_id, emp.employee_number, emp.full_name, u.email::text, emp.department,
    ev.event_type, ev.occurred_at, ev.created_at, ev.within_geofence,
    coalesce((ev.metadata ->> 'geofence_enforced')::boolean, true),
    gf.name, ev.distance_from_geofence_meters, ev.accuracy_meters,
    extensions.st_y(ev.location::extensions.geometry), extensions.st_x(ev.location::extensions.geometry),
    ev.authentication_method, ev.device_id,
    count(*) over (),
    coalesce(ev.needs_review, false),
    ev.location_status,
    ev.metadata ->> 'source',
    coalesce((ev.metadata ->> 'offline')::boolean, false),
    (ev.metadata ->> 'sync_delay_s')::integer,
    coalesce(array(select jsonb_array_elements_text(ev.metadata -> 'suspect')), '{}'::text[]),
    ev.metadata ->> 'biometric',
    coalesce((ev.metadata ->> 'missed_checkout')::boolean, false),
    case when ev.event_type = 'check_in' then private.punch_lateness(ev.employee_id, ev.id, 'check_in', ev.occurred_at) end,
    case when ev.event_type = 'check_out' then private.punch_lateness(ev.employee_id, ev.id, 'check_out', ev.occurred_at) end,
    (dd.d ->> 'minutes')::integer,
    dd.d ->> 'state'
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  join auth.users u on u.id = ev.employee_id
  left join public.employee_geofences gf on gf.id = ev.geofence_id
  left join lateral (select private.punch_deduction(ev.employee_id, ev.id, ev.occurred_at) as d where ev.event_type = 'check_in') dd on true
  where ev.company_id = v_company
    and (p_from is null or ev.occurred_at >= p_from)
    and (p_to is null or ev.occurred_at < p_to)
    and (p_employee_id is null or ev.employee_id = p_employee_id)
    and (p_event_type is null or ev.event_type = p_event_type)
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 50), 1000), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;
revoke all on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) from public, anon;
grant execute on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) to authenticated;
