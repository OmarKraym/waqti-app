-- Rollback of phase 24. Run the sections from the LAST to the first. It refuses once a request uses a custom kind (nothing is lost silently).
do $$
begin
  if exists (select 1 from public.requests where custom_kind_id is not null) then
    raise exception 'rollback_refused_custom_requests_exist';
  end if;
end
$$;

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
