-- Rollback of phase 19a: back to phase 12 (one rule: after the grace ALL the minutes count). Companies that had chosen
-- 'beyond_grace' count all minutes again from the moment this runs; nothing else is lost.
drop function if exists public.admin_set_late_rule(text);
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
  v_min integer;
begin
  select c.timezone, case p_type when 'check_in' then coalesce(e.late_grace_min, c.late_grace_min)
                                 else coalesce(e.early_grace_min, c.early_grace_min) end
    into v_tz, v_grace
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
  return case when v_min > v_grace then v_min else 0 end;
end;
$$;
revoke all on function private.punch_lateness(uuid, uuid, text, timestamptz) from public, anon, authenticated;

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
  return (select jsonb_build_object('late_grace_min', c.late_grace_min, 'early_grace_min', c.early_grace_min)
          from public.companies c where c.id = v_company);
end;
$$;

drop function if exists private.chargeable_minutes(integer, integer, text);
alter table public.companies drop column late_rule;
