-- ROLLBACK of phase 18a: back to the balances of phase 4 (whole year at once, no carry-over, no per-year edits).
-- Days charged by HR (requests.charged_days) and the per-year values are lost; the requests themselves stay.

drop function if exists public.admin_get_leave_years(uuid);
drop function if exists public.admin_set_leave_year(uuid, int, numeric, numeric, numeric);

drop function if exists public.admin_decide_request(uuid, text, text, numeric);
create or replace function public.admin_decide_request(p_request_id uuid, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
  v_ap public.request_approvals;
begin
  select a.* into v_ap from public.request_approvals a
  join public.requests r on r.id = a.request_id
  where a.request_id = p_request_id and r.company_id = v_company and a.status = 'pending' and a.approver_kind = 'hr';
  if not found then
    -- Already decided at the hr step: say so. Not (yet) at hr: it is not visible to the admin.
    if exists (select 1 from public.requests r
               join public.request_approvals a on a.request_id = r.id
               where r.id = p_request_id and r.company_id = v_company
                 and a.approver_kind = 'hr' and a.status in ('approved', 'rejected')) then
      raise exception 'already_decided' using errcode = 'P0001';
    end if;
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  return private.apply_decision(v_ap.id, p_decision, p_note, auth.uid(), false);
end;
$function$;
revoke all on function public.admin_decide_request(uuid, text, text) from public, anon;
grant execute on function public.admin_decide_request(uuid, text, text) to authenticated, service_role;

drop function if exists public.admin_get_leave_policy();
create or replace function public.admin_get_leave_policy()
 RETURNS TABLE(age_threshold integer, days_below numeric, days_at_or_above numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  -- A company without its own row sees the defaults (50 years / 30 / 45 days).
  return query
  select coalesce(lp.age_threshold, 50)::integer, coalesce(lp.days_below, 30), coalesce(lp.days_at_or_above, 45)
  from (select 1) one
  left join public.leave_policy lp on lp.company_id = v_company;
end;
$function$;
revoke all on function public.admin_get_leave_policy() from public, anon;
grant execute on function public.admin_get_leave_policy() to authenticated, service_role;

drop function if exists public.admin_set_leave_policy(integer, numeric, numeric, numeric);
create or replace function public.admin_set_leave_policy(p_age_threshold integer, p_days_below numeric, p_days_at_or_above numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.require_company_admin();
begin
  if p_age_threshold is null or p_age_threshold not between 18 and 100
     or p_days_below is null or p_days_below not between 0 and 366
     or p_days_at_or_above is null or p_days_at_or_above not between 0 and 366 then
    raise exception 'invalid_policy' using errcode = '22023';
  end if;
  insert into public.leave_policy (company_id, age_threshold, days_below, days_at_or_above)
  values (v_company, p_age_threshold, p_days_below, p_days_at_or_above)
  on conflict (company_id) do update
    set age_threshold = excluded.age_threshold, days_below = excluded.days_below, days_at_or_above = excluded.days_at_or_above;
  perform public.audit_write(v_company, 'leave_policy.set', 'company', v_company::text,
    jsonb_build_object('age_threshold', p_age_threshold, 'days_below', p_days_below, 'days_at_or_above', p_days_at_or_above));
end;
$function$;
revoke all on function public.admin_set_leave_policy(integer, numeric, numeric) from public, anon;
grant execute on function public.admin_set_leave_policy(integer, numeric, numeric) to authenticated, service_role;

create or replace function public.employee_submit_request(p_request_key uuid, p_type text, p_leave_type text DEFAULT NULL::text, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date, p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_reason text DEFAULT NULL::text, p_dry_run boolean DEFAULT false, p_permission_type_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

create or replace function private.apply_decision(p_approval_id uuid, p_decision text, p_note text, p_actor uuid, p_override boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function private.apply_decision(uuid, text, text, uuid, boolean) from public, anon, authenticated;

create or replace function private.request_json(p_request uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
revoke all on function private.request_json(uuid) from public, anon, authenticated;

drop function if exists private.leave_balance(uuid, text, integer, uuid, date);
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
revoke all on function private.leave_balance(uuid, text, integer, uuid) from public, anon, authenticated;

drop function if exists private.annual_carried(uuid, int);
drop function if exists private.annual_taken(uuid, int, uuid);
drop function if exists private.annual_first_year(uuid);
drop function if exists private.annual_earned(numeric, int, date, date);
drop function if exists private.annual_year_days(uuid, int);
drop table if exists public.employee_leave_years;
alter table public.requests drop column if exists charged_days;
alter table public.companies drop column if exists annual_carryover_max;

