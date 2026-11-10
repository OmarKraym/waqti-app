-- Rollback of phase 24. Run the whole file once; its sections run from the LAST (G) to the first (A). It refuses once a request uses a custom kind (nothing is lost silently).
do $$
begin
  if exists (select 1 from public.requests where custom_kind_id is not null) then
    raise exception 'rollback_refused_custom_requests_exist';
  end if;
end
$$;

-- ---------------------------------------------------------------- G. what the app and the people see (restore phase 18b / 5 / 18a / 4d)
create or replace function private.request_json(p_request uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id, 'type', r.request_type, 'leave_type', r.leave_type, 'status', r.status,
    'permission_type_id', r.permission_type_id, 'permission_type', pt.name,
    'start_at', r.start_at, 'end_at', r.end_at, 'days', r.days, 'charged_days', r.charged_days, 'minutes', r.minutes,
    'company_leave_day_id', r.company_leave_day_id,
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
$$;
revoke all on function private.request_json(uuid) from public, anon, authenticated;

create or replace function private.request_summary(p_request uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case r.request_type
    when 'leave' then
      'إجازة ' || case r.leave_type when 'annual' then 'سنوية' when 'sick' then 'مرضية' when 'emergency' then 'طارئة'
                                    when 'marriage' then 'زواج' when 'maternity' then 'أمومة' when 'unpaid' then 'بدون راتب' else '' end
      || ' · ' || private.days_text(r.days) || ' · '
      || to_char(r.start_at at time zone c.timezone, 'DD/MM')
      || case when (r.end_at - interval '1 second') at time zone c.timezone >= (r.start_at at time zone c.timezone)::date + 1
              then ' – ' || to_char((r.end_at - interval '1 second') at time zone c.timezone, 'DD/MM') else '' end
    when 'permission' then
      'إذن: ' || coalesce(pt.name, '') || ' · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM HH24:MI')
      || '–' || to_char(r.end_at at time zone c.timezone, 'HH24:MI')
    else
      'طلب آخر · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM')
  end
  from public.requests r
  join public.companies c on c.id = r.company_id
  left join public.permission_types pt on pt.id = r.permission_type_id
  where r.id = p_request
$$;
revoke all on function private.request_summary(uuid) from public, anon, authenticated;

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
      -- Final approval: the balance must still allow it (other requests may have been approved meanwhile),
      -- unless the employee gave a reason for asking more (phase 18a): then the approvers decided knowingly.
      if v_req.request_type = 'leave' and v_req.reason is null then
        select c.timezone into v_tz from public.companies c where c.id = v_req.company_id;
        v_bal := private.leave_balance(v_req.employee_id, v_req.leave_type,
                   extract(year from (v_req.start_at at time zone v_tz))::int, v_req.id);
        if (v_bal ->> 'remaining') is not null
           and (v_bal ->> 'remaining')::numeric + (v_bal ->> 'pending')::numeric < coalesce(v_req.charged_days, v_req.days) then
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
    'permission_types', coalesce((
      select jsonb_agg(private.permission_usage(me.employee_id, pt.id, date_trunc('month', v_today)::date) order by pt.sort_order, pt.name)
      from public.permission_types pt
      where pt.company_id = me.company_id and pt.is_active), '[]'::jsonb),
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

-- ---------------------------------------------------------------- E. employee: submit (restore the phase 18a function, 10 arguments)
drop function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid, uuid);
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
  v_over boolean := false;
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
    -- Annual leave: what was earned up to the first day of the leave. More than the balance needs a reason (HR decides).
    v_bal := private.leave_balance(me.employee_id, p_leave_type, extract(year from p_start_date)::int, null, p_start_date);
    if (v_bal ->> 'remaining') is not null and (v_bal ->> 'remaining')::numeric < v_days then
      v_over := true;
      if v_reason is null and not p_dry_run then
        raise exception 'insufficient_balance' using errcode = 'P0001';
      end if;
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
      'balance', v_bal, 'permission', v_perm, 'over_balance', v_over);
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
revoke all on function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid) from public, anon;
grant execute on function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid) to authenticated;

-- ---------------------------------------------------------------- D. approval paths per custom kind
drop function public.admin_set_approval_chain(text, jsonb, uuid, uuid);
drop function private.request_chain(uuid, public.request_type, uuid, uuid);
create or replace function private.request_chain(p_company uuid, p_type public.request_type, p_permission_type uuid default null)
returns table (step_order smallint, approver_kind text, approver_employee_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select s.step_order, s.approver_kind, s.approver_employee_id
  from public.approval_steps s
  where s.company_id = p_company and s.request_type = p_type and s.permission_type_id is not distinct from p_permission_type
  union all
  select d.step_order, d.approver_kind, null::uuid
  from (values (1::smallint, 'direct_manager'), (2::smallint, 'hr')) as d (step_order, approver_kind)
  where not exists (select 1 from public.approval_steps s
                    where s.company_id = p_company and s.request_type = p_type
                      and s.permission_type_id is not distinct from p_permission_type)
  order by 1
$$;
revoke all on function private.request_chain(uuid, public.request_type, uuid) from public, anon, authenticated;

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
    'chains', (
      select jsonb_object_agg(t, coalesce((
        select jsonb_agg(jsonb_build_object('step_order', c.step_order, 'kind', c.approver_kind,
                 'approver_employee_id', c.approver_employee_id,
                 'approver_name', (select e.full_name from public.employees e where e.id = c.approver_employee_id))
               order by c.step_order)
        from private.request_chain(v_company, t::public.request_type) c), '[]'::jsonb))
      from unnest(array['leave', 'other']) as t),
    'customized', (
      select coalesce(jsonb_agg(distinct s.request_type), '[]'::jsonb)
      from public.approval_steps s where s.company_id = v_company and s.request_type <> 'permission'),
    'permission_types', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pt.id, 'name', pt.name, 'is_active', pt.is_active,
               'customized', exists (select 1 from public.approval_steps s where s.permission_type_id = pt.id),
               'steps', coalesce((
                 select jsonb_agg(jsonb_build_object('step_order', c.step_order, 'kind', c.approver_kind,
                          'approver_employee_id', c.approver_employee_id,
                          'approver_name', (select e.full_name from public.employees e where e.id = c.approver_employee_id))
                        order by c.step_order)
                 from private.request_chain(v_company, 'permission', pt.id) c), '[]'::jsonb))
             order by pt.sort_order, pt.name)
      from public.permission_types pt where pt.company_id = v_company), '[]'::jsonb));
end;
$$;

-- For 'permission', p_permission_type_id says which type; for 'leave' and 'other' it must be null.
create or replace function public.admin_set_approval_chain(p_request_type text, p_steps jsonb, p_permission_type_id uuid default null)
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
     or jsonb_typeof(p_steps) is distinct from 'array' or jsonb_array_length(p_steps) > 5
     or (p_request_type = 'permission') <> (p_permission_type_id is not null) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_permission_type_id is not null
     and not exists (select 1 from public.permission_types where id = p_permission_type_id and company_id = v_company) then
    raise exception 'permission_type_not_found' using errcode = '22023';
  end if;
  delete from public.approval_steps
   where company_id = v_company and request_type = p_request_type::public.request_type
     and permission_type_id is not distinct from p_permission_type_id;
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
    insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id, permission_type_id)
    values (v_company, p_request_type::public.request_type, v_order, v_kind, v_emp, p_permission_type_id);
  end loop;
  perform public.audit_write(v_company, 'approval_chain.set', 'company', v_company::text,
    jsonb_build_object('request_type', p_request_type, 'permission_type_id', p_permission_type_id, 'steps', p_steps));
exception
  when invalid_text_representation then
    raise exception 'invalid_input' using errcode = '22023';
end;
$$;
revoke execute on function public.admin_set_approval_chain(text, jsonb, uuid) from public, anon;
grant execute on function public.admin_set_approval_chain(text, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------- C. balance and days per employee
drop function public.admin_set_employee_kind_days(uuid, jsonb);
drop function public.admin_get_employee_kind_days(uuid);
drop function private.custom_leave_balance(uuid, uuid, integer, uuid);

-- ---------------------------------------------------------------- B. admin: the kinds
drop function public.admin_delete_custom_kind(uuid);
drop function public.admin_save_custom_kind(uuid, text, text, boolean, numeric, text, boolean, text, integer);
drop function public.admin_list_custom_kinds();

-- ---------------------------------------------------------------- A. schema
delete from public.approval_steps where custom_kind_id is not null;
drop index public.approval_steps_order_uidx;
alter table public.approval_steps
  drop constraint approval_steps_custom_kind_check,
  drop constraint approval_steps_custom_kind_same_company,
  drop column custom_kind_id;
create unique index approval_steps_order_uidx on public.approval_steps
  (company_id, request_type, coalesce(permission_type_id, '00000000-0000-0000-0000-000000000000'::uuid), step_order);

alter table public.requests
  drop constraint requests_custom_kind_shape,
  drop constraint requests_leave_type_check,
  drop constraint requests_custom_kind_same_company,
  drop column custom_kind_id;
alter table public.requests
  add constraint requests_leave_type_check check (leave_type in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid'));

drop table public.custom_kind_entitlements;
drop table public.custom_request_kinds;
