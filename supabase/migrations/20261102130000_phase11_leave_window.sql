-- Phase 11: WHEN may an employee ask for leave (company setting, changed by the admin).
--   * companies.leave_back_days   = how many days back a leave may START (0 = not before today)
--   * companies.leave_notice_days = how many days ahead it must START (0 = today is fine)
--   * earliest allowed start = today + notice - back (today = the company's day). Only one of the two may be above 0.
--   * enforced HERE by a trigger on public.requests (every leave goes through employee_submit_request), not only in the app.
--     A refused leave raises leave_date_not_allowed. Permissions and "other" requests are not affected.
--   * employee_leave_window() tells the app the earliest date so the date box can stop earlier days.
-- Old rule was: a leave could start up to 30 days in the past. New default is 0 (today or later).
-- Rollback: 20261102130000_phase11_leave_window_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('public.employee_requests_overview()') is null
     or to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.require_active_employee()') is null then
    raise exception 'phase11: expected functions are missing';
  end if;
end
$guard$;

alter table public.companies
  add column leave_back_days smallint not null default 0 check (leave_back_days between 0 and 365),
  add column leave_notice_days smallint not null default 0 check (leave_notice_days between 0 and 365),
  add constraint companies_leave_window_one_way check (leave_back_days = 0 or leave_notice_days = 0);

-- The earliest day a leave may start, for a company, given its "today".
create or replace function private.leave_earliest(p_company uuid, p_today date)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select p_today + c.leave_notice_days - c.leave_back_days from public.companies c where c.id = p_company
$$;
revoke all on function private.leave_earliest(uuid, date) from public, anon, authenticated;

create or replace function private.enforce_leave_window()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_company uuid;
  v_today date;
begin
  if new.request_type::text <> 'leave' then
    return new;
  end if;
  select c.timezone, c.id into v_tz, v_company
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = new.employee_id;
  v_today := (now() at time zone v_tz)::date;
  if (new.start_at at time zone v_tz)::date < private.leave_earliest(v_company, v_today) then
    raise exception 'leave_date_not_allowed' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function private.enforce_leave_window() from public, anon, authenticated;

create trigger requests_leave_window before insert on public.requests
  for each row execute function private.enforce_leave_window();

-- Employee: the earliest date the date box may offer.
create or replace function public.employee_leave_window()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_today date;
begin
  select * into me from public.require_active_employee();
  v_today := (now() at time zone me.timezone)::date;
  return jsonb_build_object('today', v_today, 'earliest', private.leave_earliest(me.company_id, v_today));
end;
$$;
revoke all on function public.employee_leave_window() from public, anon;
grant execute on function public.employee_leave_window() to authenticated;

-- Admin: read and change the rule.
create or replace function public.admin_get_leave_window()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return (select jsonb_build_object('back_days', c.leave_back_days, 'notice_days', c.leave_notice_days)
          from public.companies c where c.id = v_company);
end;
$$;
revoke all on function public.admin_get_leave_window() from public, anon;
grant execute on function public.admin_get_leave_window() to authenticated;

create or replace function public.admin_set_leave_window(p_back_days integer, p_notice_days integer)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_back_days is null or p_notice_days is null
     or p_back_days not between 0 and 365 or p_notice_days not between 0 and 365
     or (p_back_days > 0 and p_notice_days > 0) then
    raise exception 'invalid_settings' using errcode = '22023';
  end if;
  update public.companies set leave_back_days = p_back_days, leave_notice_days = p_notice_days where id = v_company;
  perform public.audit_write(v_company, 'company.leave_window', 'company', v_company::text,
    jsonb_build_object('back_days', p_back_days, 'notice_days', p_notice_days));
  return public.admin_get_leave_window();
end;
$$;
revoke all on function public.admin_set_leave_window(integer, integer) from public, anon;
grant execute on function public.admin_set_leave_window(integer, integer) to authenticated;
