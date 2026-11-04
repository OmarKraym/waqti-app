-- Rollback of phase 16c: back to the old get_my_profile() (unfiltered, as in the baseline), no summary, no switches.
drop function if exists public.admin_set_profile_visibility(jsonb);
drop function if exists public.admin_get_profile_visibility();
drop function if exists public.employee_profile_summary() cascade;
drop function if exists private.profile_visibility(uuid);
drop function if exists private.profile_visibility_defaults();
alter table public.companies drop constraint if exists companies_profile_visibility_object;
alter table public.companies drop column if exists profile_visibility;

CREATE OR REPLACE FUNCTION public.get_my_profile()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_emp public.employees;
  v_base numeric;
  v_components_total numeric;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_emp from public.employees where id = v_uid;
  if not found then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  if not v_emp.is_active then
    raise exception 'employee_not_active' using errcode = '42501';
  end if;

  select c.base_salary into v_base from public.employee_compensation c where c.employee_id = v_uid;
  select coalesce(sum(s.amount), 0) into v_components_total from public.employee_salary_components s where s.employee_id = v_uid;

  return jsonb_build_object(
    'employee', jsonb_build_object(
      'employee_number', v_emp.employee_number,
      'full_name', v_emp.full_name,
      'department', v_emp.department,
      'job_title', v_emp.job_title,
      'gender', v_emp.gender,
      'birth_date', v_emp.birth_date,
      'hire_date', v_emp.hire_date,
      'work_location_name', (select w.name from public.work_locations w where w.id = v_emp.work_location_id)
    ),
    'schedule', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', w.weekday, 'is_workday', w.is_workday,
        'start_time', to_char(w.start_time, 'HH24:MI'), 'end_time', to_char(w.end_time, 'HH24:MI')
      ) order by w.weekday)
      from public.employee_work_schedules w where w.employee_id = v_uid
    ), '[]'::jsonb),
    'salary', case when v_base is null then null else jsonb_build_object(
      'base_salary', v_base,
      'components', coalesce((
        select jsonb_agg(jsonb_build_object('name', s.name, 'amount', s.amount) order by s.sort_order, s.id)
        from public.employee_salary_components s where s.employee_id = v_uid
      ), '[]'::jsonb),
      'total', v_base + v_components_total
    ) end,
    'leave', coalesce((
      select jsonb_agg(q.item order by q.ord)
      from (
        select jsonb_build_object('type', l.leave_type, 'days', l.days, 'is_default', false) as item,
               array_position(array['annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid'], l.leave_type) as ord
        from public.employee_leave_entitlements l
        where l.employee_id = v_uid
        union all
        select jsonb_build_object('type', 'annual',
                 'days', coalesce(public.default_annual_leave_days(v_emp.company_id, v_emp.birth_date),
                                  case when date_part('year', age(current_date, v_emp.birth_date)) >= 50 then 45 else 30 end),
                 'is_default', true), 1
        where v_emp.birth_date is not null
          and not exists (select 1 from public.employee_leave_entitlements l2 where l2.employee_id = v_uid and l2.leave_type = 'annual')
      ) q
    ), '[]'::jsonb)
  );
end;
$function$
;
revoke all on function public.get_my_profile() from public, anon;
grant execute on function public.get_my_profile() to authenticated;
