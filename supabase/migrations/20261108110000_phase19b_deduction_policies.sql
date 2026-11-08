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
