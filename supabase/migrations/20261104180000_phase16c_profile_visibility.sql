-- Phase 16c: the employee sees a summary of his own data on "My account"; the company admin chooses which parts.
-- Spec: docs/superpowers/specs/2026-11-02-profile-summary-visibility-design.md (planned as "phase11"; renamed, phase 11 is taken).
--   companies.profile_visibility            stored switches (only the ones changed; the rest use the defaults)
--   private.profile_visibility_defaults()   the 11 keys and their defaults (salary, birth date, gender start hidden)
--   private.profile_visibility(uuid)        effective map for a company = defaults || stored (unknown stored keys ignored)
--   public.employee_profile_summary()       the caller's OWN data; every hidden item is left out (absent, not null)
--   public.admin_get_profile_visibility()   effective map (company admin)
--   public.admin_set_profile_visibility(jsonb)   merge + audit (company admin)
--   public.get_my_profile()                 now the same filtered summary (it returned salary to anyone before)
-- Rollback: 20261104180000_phase16c_profile_visibility_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('public.require_active_employee()') is null
     or to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regprocedure('public.default_annual_leave_days(uuid, date, date)') is null
     or to_regprocedure('public.get_my_profile()') is null then
    raise exception 'phase16c: expected objects are missing';
  end if;
end
$guard$;

alter table public.companies
  add column if not exists profile_visibility jsonb not null default '{}'::jsonb;
alter table public.companies drop constraint if exists companies_profile_visibility_object;
alter table public.companies
  add constraint companies_profile_visibility_object check (jsonb_typeof(profile_visibility) = 'object');

-- ---------------------------------------------------------------- defaults and effective map
create or replace function private.profile_visibility_defaults()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{"department": true, "job_title": true, "work_location": true, "hire_date": true, "schedule": true, "leave": true,
           "salary_base": false, "salary_components": false, "salary_total": false, "birth_date": false, "gender": false}'::jsonb
$$;
revoke all on function private.profile_visibility_defaults() from public, anon, authenticated;

create or replace function private.profile_visibility(p_company uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_object_agg(d.key, coalesce(case when jsonb_typeof(c.profile_visibility -> d.key) = 'boolean'
                                               then c.profile_visibility -> d.key end, d.value))
  from jsonb_each(private.profile_visibility_defaults()) d
  left join public.companies c on c.id = p_company
$$;
revoke all on function private.profile_visibility(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- the employee's own summary
create or replace function public.employee_profile_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me record;
  v_emp public.employees;
  v jsonb;
  on_ boolean;
  v_employee jsonb := '{}'::jsonb;
  v_salary jsonb := '{}'::jsonb;
  v_out jsonb := '{}'::jsonb;
  v_base numeric;
  v_sum numeric;
begin
  select * into me from public.require_active_employee();
  select * into v_emp from public.employees where id = me.employee_id;
  v := private.profile_visibility(v_emp.company_id);

  if (v ->> 'department')::boolean then v_employee := v_employee || jsonb_build_object('department', v_emp.department); end if;
  if (v ->> 'job_title')::boolean then v_employee := v_employee || jsonb_build_object('job_title', v_emp.job_title); end if;
  if (v ->> 'work_location')::boolean then
    v_employee := v_employee || jsonb_build_object('work_location_name',
      (select w.name from public.work_locations w where w.id = v_emp.work_location_id));
  end if;
  if (v ->> 'hire_date')::boolean then v_employee := v_employee || jsonb_build_object('hire_date', v_emp.hire_date); end if;
  if (v ->> 'birth_date')::boolean then v_employee := v_employee || jsonb_build_object('birth_date', v_emp.birth_date); end if;
  if (v ->> 'gender')::boolean then v_employee := v_employee || jsonb_build_object('gender', v_emp.gender); end if;
  if v_employee <> '{}'::jsonb then v_out := v_out || jsonb_build_object('employee', v_employee); end if;

  if (v ->> 'schedule')::boolean then
    v_out := v_out || jsonb_build_object('schedule', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', w.weekday, 'is_workday', w.is_workday,
        'start_time', to_char(w.start_time, 'HH24:MI'), 'end_time', to_char(w.end_time, 'HH24:MI')
      ) order by w.weekday)
      from public.employee_work_schedules w where w.employee_id = v_emp.id), '[]'::jsonb));
  end if;

  if (v ->> 'salary_base')::boolean or (v ->> 'salary_components')::boolean or (v ->> 'salary_total')::boolean then
    select c.base_salary into v_base from public.employee_compensation c where c.employee_id = v_emp.id;
    if v_base is not null then
      select coalesce(sum(s.amount), 0) into v_sum from public.employee_salary_components s where s.employee_id = v_emp.id;
      if (v ->> 'salary_base')::boolean then v_salary := v_salary || jsonb_build_object('base_salary', v_base); end if;
      if (v ->> 'salary_components')::boolean then
        v_salary := v_salary || jsonb_build_object('components', coalesce((
          select jsonb_agg(jsonb_build_object('name', s.name, 'amount', s.amount) order by s.sort_order, s.id)
          from public.employee_salary_components s where s.employee_id = v_emp.id), '[]'::jsonb));
      end if;
      if (v ->> 'salary_total')::boolean then v_salary := v_salary || jsonb_build_object('total', v_base + v_sum); end if;
      v_out := v_out || jsonb_build_object('salary', v_salary);
    end if;
  end if;

  if (v ->> 'leave')::boolean then
    v_out := v_out || jsonb_build_object('leave', coalesce((
      select jsonb_agg(q.item order by q.ord)
      from (
        select jsonb_build_object('type', l.leave_type, 'days', l.days, 'is_default', false) as item,
               array_position(array['annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid'], l.leave_type) as ord
        from public.employee_leave_entitlements l
        where l.employee_id = v_emp.id
        union all
        select jsonb_build_object('type', 'annual',
                 'days', coalesce(public.default_annual_leave_days(v_emp.company_id, v_emp.birth_date),
                                  case when date_part('year', age(current_date, v_emp.birth_date)) >= 50 then 45 else 30 end),
                 'is_default', true), 1
        where v_emp.birth_date is not null
          and not exists (select 1 from public.employee_leave_entitlements l2 where l2.employee_id = v_emp.id and l2.leave_type = 'annual')
      ) q), '[]'::jsonb));
  end if;

  return v_out;
end;
$$;
revoke all on function public.employee_profile_summary() from public, anon;
grant execute on function public.employee_profile_summary() to authenticated;

-- The old function returned everything (salary included) to any signed-in employee: one filter, one door.
create or replace function public.get_my_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return public.employee_profile_summary();
end;
$$;
revoke all on function public.get_my_profile() from public, anon;
grant execute on function public.get_my_profile() to authenticated;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_get_profile_visibility()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.profile_visibility(public.require_company_admin());
end;
$$;
revoke all on function public.admin_get_profile_visibility() from public, anon;
grant execute on function public.admin_get_profile_visibility() to authenticated;

create or replace function public.admin_set_profile_visibility(p_visibility jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_old jsonb;
  v_new jsonb;
  v_changed jsonb := '{}'::jsonb;
  k text;
begin
  if p_visibility is null or jsonb_typeof(p_visibility) <> 'object'
     or exists (select 1 from jsonb_each(p_visibility) e
                where not private.profile_visibility_defaults() ? e.key or jsonb_typeof(e.value) <> 'boolean') then
    raise exception 'invalid_profile_visibility' using errcode = '22023';
  end if;

  perform 1 from public.companies where id = v_company for update;
  v_old := private.profile_visibility(v_company);
  update public.companies
     set profile_visibility = (select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
                               from jsonb_each(profile_visibility || p_visibility) e
                               where private.profile_visibility_defaults() ? e.key)
   where id = v_company;
  v_new := private.profile_visibility(v_company);

  for k in select key from jsonb_each(v_new) loop
    if v_new -> k <> v_old -> k then
      v_changed := v_changed || jsonb_build_object(k, jsonb_build_object('from', v_old -> k, 'to', v_new -> k));
    end if;
  end loop;
  if v_changed <> '{}'::jsonb then
    perform public.audit_write(v_company, 'company.profile_visibility', 'company', v_company::text, jsonb_build_object('changed', v_changed));
  end if;
  return v_new;
end;
$$;
revoke all on function public.admin_set_profile_visibility(jsonb) from public, anon;
grant execute on function public.admin_set_profile_visibility(jsonb) to authenticated;
