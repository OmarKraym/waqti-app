-- Phase 19a: company late rule (how the grace period counts).
--   * companies.late_rule:
--       'all_after_grace' (the default, phase 12 behaviour): within the grace = 0; beyond it ALL the minutes since the
--                         shift start (or until its end) count.
--       'beyond_grace'  : within the grace = 0; beyond it only the minutes AFTER the grace count.
--     One rule for late arrival and early leave. Nothing changes for a company until its admin picks the other rule.
--   * private.punch_lateness reads the rule (same signature, same "first check-in / last check-out / day off = null").
--   * admin_get_grace_settings also returns late_rule; admin_set_late_rule(text) changes it (audited).
-- Nothing is blocked or rejected: this only decides what is marked (and, in phase 19b, deducted).
-- Rollback: 20261108100000_phase19a_late_rule_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('private.punch_lateness(uuid, uuid, text, timestamptz)') is null
     or to_regprocedure('public.admin_get_grace_settings()') is null
     or to_regprocedure('public.require_company_admin()') is null then
    raise exception 'phase19a: run phase 12 first (grace period)';
  end if;
end
$guard$;

alter table public.companies
  add column late_rule text not null default 'all_after_grace' check (late_rule in ('all_after_grace', 'beyond_grace'));

-- Minutes late (check-in) or early (check-out) of one punch, or null when it does not apply. Counted by the company rule.
create or replace function private.punch_lateness(p_employee uuid, p_event uuid, p_type text, p_at timestamptz)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_day date;
  v_start timestamptz;
  v_end timestamptz;
  v_grace integer;
  v_rule text;
  v_min integer;
begin
  select c.timezone, case p_type when 'check_in' then coalesce(e.late_grace_min, c.late_grace_min)
                                 else coalesce(e.early_grace_min, c.early_grace_min) end, c.late_rule
    into v_tz, v_grace, v_rule
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = p_employee;
  if v_tz is null then return null; end if;
  v_day := (p_at at time zone v_tz)::date;
  select s.shift_start, s.shift_end into v_start, v_end from private.shift_bounds(p_employee, v_day, v_tz) s;
  if v_start is null or v_end <= v_start then return null; end if;   -- day off, or a shift that crosses midnight

  if p_type = 'check_in' then
    if exists (select 1 from public.attendance_events x
               where x.employee_id = p_employee and x.event_type = 'check_in'
                 and (x.occurred_at at time zone v_tz)::date = v_day
                 and (x.occurred_at, x.id) < (p_at, p_event)) then
      return null;                                                    -- not the first arrival of the day
    end if;
    v_min := greatest(ceil(extract(epoch from (p_at - v_start)) / 60)::integer, 0);
  else
    if exists (select 1 from public.attendance_events x
               where x.employee_id = p_employee and x.event_type = 'check_out'
                 and (x.occurred_at at time zone v_tz)::date = v_day
                 and (x.occurred_at, x.id) > (p_at, p_event)) then
      return null;                                                    -- not the last departure of the day
    end if;
    v_min := greatest(ceil(extract(epoch from (v_end - p_at)) / 60)::integer, 0);
  end if;
  return case when v_min <= v_grace then 0
              when v_rule = 'beyond_grace' then v_min - v_grace
              else v_min end;
end;
$$;
revoke all on function private.punch_lateness(uuid, uuid, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- admin: company default (+ the rule)
create or replace function public.admin_get_grace_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return (select jsonb_build_object('late_grace_min', c.late_grace_min, 'early_grace_min', c.early_grace_min, 'late_rule', c.late_rule)
          from public.companies c where c.id = v_company);
end;
$$;

create or replace function public.admin_set_late_rule(p_rule text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_rule is null or p_rule not in ('all_after_grace', 'beyond_grace') then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.companies set late_rule = p_rule where id = v_company;
  perform public.audit_write(v_company, 'company.late_rule', 'company', v_company::text, jsonb_build_object('late_rule', p_rule));
  return public.admin_get_grace_settings();
end;
$$;
revoke all on function public.admin_set_late_rule(text) from public, anon;
grant execute on function public.admin_set_late_rule(text) to authenticated;
