-- Phase 24: custom request kinds.
-- The admin can add new LEAVE types and new «طلب آخر» types (a name and a few settings); the six built-in leave types and today's
-- «طلب آخر» are not touched. Spec: docs/superpowers/specs/2026-11-09-custom-request-kinds-design.md.
--   A. schema: custom_request_kinds, custom_kind_entitlements, requests.custom_kind_id, approval_steps.custom_kind_id
--   B. admin RPCs for kinds                          (added by the next task sections)
-- Rollback: …_ROLLBACK.sql (refuses to run once a request uses a kind).

-- ---------------------------------------------------------------- A. schema
create table public.custom_request_kinds (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  family text not null check (family in ('leave', 'other')),
  name text not null,
  enabled boolean not null default true,
  sort_order smallint not null default 0,
  default_days numeric(5, 1),                       -- leave only; NULL = unlimited, 0 = no days
  gender text not null default 'all',               -- leave only
  reason_required boolean not null default false,   -- leave only
  date_mode text,                                   -- other only
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint custom_request_kinds_company_id_key unique (company_id, id),
  constraint custom_request_kinds_name_check check (length(btrim(name)) between 1 and 60),
  constraint custom_request_kinds_days_check check (default_days is null or (default_days >= 0 and default_days <= 366)),
  constraint custom_request_kinds_gender_check check (gender in ('all', 'female', 'male')),
  constraint custom_request_kinds_date_mode_check check (date_mode is null or date_mode in ('single', 'range', 'none')),
  constraint custom_request_kinds_family_fields check (
    (family = 'leave' and date_mode is null)
    or (family = 'other' and date_mode is not null and default_days is null and gender = 'all' and reason_required = false))
);
create unique index custom_request_kinds_name_uidx on public.custom_request_kinds (company_id, family, lower(btrim(name)));

-- Per-employee days of a leave kind. No row = the kind's default_days.
create table public.custom_kind_entitlements (
  company_id uuid not null,
  kind_id uuid not null,
  employee_id uuid not null,
  days numeric(5, 1) not null,
  primary key (kind_id, employee_id),
  constraint custom_kind_entitlements_days_check check (days >= 0 and days <= 366),
  constraint custom_kind_entitlements_kind_same_company
    foreign key (company_id, kind_id) references public.custom_request_kinds (company_id, id) on delete cascade,
  constraint custom_kind_entitlements_employee_same_company
    foreign key (company_id, employee_id) references public.employees (company_id, id) on delete cascade
);

alter table public.custom_request_kinds enable row level security;
alter table public.custom_kind_entitlements enable row level security;
revoke all on public.custom_request_kinds, public.custom_kind_entitlements from anon, authenticated;

-- requests: the kind a request was made under. A custom leave carries leave_type = 'custom'.
alter table public.requests
  add column custom_kind_id uuid,
  add constraint requests_custom_kind_same_company
    foreign key (company_id, custom_kind_id) references public.custom_request_kinds (company_id, id) on delete restrict;
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%annual%' loop
    execute format('alter table public.requests drop constraint %I', c);
  end loop;
end
$$;
alter table public.requests
  add constraint requests_leave_type_check
    check (leave_type in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid', 'custom')),
  add constraint requests_custom_kind_shape check (
    case request_type
      when 'leave' then (leave_type = 'custom') = (custom_kind_id is not null)
      when 'other' then true
      else custom_kind_id is null end);

-- approval_steps: a chain per custom «other» kind (custom leave kinds use the shared leave chain).
alter table public.approval_steps
  add column custom_kind_id uuid,
  add constraint approval_steps_custom_kind_same_company
    foreign key (company_id, custom_kind_id) references public.custom_request_kinds (company_id, id) on delete cascade,
  add constraint approval_steps_custom_kind_check check (custom_kind_id is null or (request_type = 'other' and permission_type_id is null));
drop index public.approval_steps_order_uidx;
create unique index approval_steps_order_uidx on public.approval_steps
  (company_id, request_type, coalesce(permission_type_id, '00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(custom_kind_id, '00000000-0000-0000-0000-000000000000'::uuid), step_order);

-- ---------------------------------------------------------------- B. admin: the kinds
create or replace function public.admin_list_custom_kinds()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', k.id, 'family', k.family, 'name', k.name, 'enabled', k.enabled, 'sort_order', k.sort_order,
             'default_days', k.default_days, 'gender', k.gender, 'reason_required', k.reason_required, 'date_mode', k.date_mode,
             'requests_count', (select count(*) from public.requests r where r.custom_kind_id = k.id),
             'pending_count', (select count(*) from public.requests r where r.custom_kind_id = k.id and r.status = 'pending'))
           order by k.family, k.sort_order, k.name)
    from public.custom_request_kinds k where k.company_id = v_company), '[]'::jsonb);
end;
$$;

-- p_id null = a new kind. The family never changes. A kind that a request used is never deleted: disable it instead.
create or replace function public.admin_save_custom_kind(
  p_id uuid, p_family text, p_name text, p_enabled boolean, p_default_days numeric, p_gender text,
  p_reason_required boolean, p_date_mode text, p_sort_order integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_old public.custom_request_kinds;
  v_id uuid;
begin
  if length(v_name) not between 1 and 60 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_family is null or p_family not in ('leave', 'other') or p_enabled is null
     or coalesce(p_sort_order, 0) not between 0 and 1000
     or (p_family = 'leave' and (
           p_date_mode is not null or p_reason_required is null
           or p_gender is null or p_gender not in ('all', 'female', 'male')
           or (p_default_days is not null and p_default_days not between 0 and 366)))
     or (p_family = 'other' and (
           p_date_mode is null or p_date_mode not in ('single', 'range', 'none')
           or p_default_days is not null or coalesce(p_gender, 'all') <> 'all' or coalesce(p_reason_required, false))) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  -- two admins saving at once: the count and the name check below must see each other
  perform pg_advisory_xact_lock(hashtextextended('custom_kinds:' || v_company::text, 0));

  if p_id is not null then
    select * into v_old from public.custom_request_kinds where id = p_id and company_id = v_company for update;
    if not found then
      raise exception 'custom_kind_not_found' using errcode = '22023';
    end if;
    if v_old.family <> p_family then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
  end if;
  if exists (select 1 from public.custom_request_kinds
             where company_id = v_company and family = p_family and lower(btrim(name)) = lower(v_name) and id is distinct from p_id) then
    raise exception 'kind_name_taken' using errcode = '22023';
  end if;

  if p_id is null then
    if (select count(*) from public.custom_request_kinds where company_id = v_company and family = p_family) >= 30 then
      raise exception 'kind_limit' using errcode = 'P0001';
    end if;
    insert into public.custom_request_kinds (company_id, family, name, enabled, sort_order, default_days, gender, reason_required, date_mode)
    values (v_company, p_family, v_name, p_enabled, coalesce(p_sort_order, 0), p_default_days,
            case when p_family = 'leave' then p_gender else 'all' end, coalesce(p_reason_required, false), p_date_mode)
    returning id into v_id;
  else
    update public.custom_request_kinds
       set name = v_name, enabled = p_enabled, sort_order = coalesce(p_sort_order, 0), default_days = p_default_days,
           gender = case when p_family = 'leave' then p_gender else 'all' end,
           reason_required = coalesce(p_reason_required, false), date_mode = p_date_mode, updated_at = now()
     where id = p_id
    returning id into v_id;
  end if;

  perform public.audit_write(v_company, case when p_id is null then 'custom_kind.create' else 'custom_kind.update' end,
    'custom_kind', v_id::text,
    jsonb_build_object('family', p_family, 'name', v_name, 'enabled', p_enabled, 'default_days', p_default_days,
                       'gender', p_gender, 'reason_required', p_reason_required, 'date_mode', p_date_mode, 'sort_order', coalesce(p_sort_order, 0)));
  return v_id;
end;
$$;

create or replace function public.admin_delete_custom_kind(p_id uuid)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_kind public.custom_request_kinds;
begin
  select * into v_kind from public.custom_request_kinds where id = p_id and company_id = v_company for update;
  if not found then
    raise exception 'custom_kind_not_found' using errcode = '22023';
  end if;
  if exists (select 1 from public.requests r where r.custom_kind_id = p_id) then
    raise exception 'kind_in_use' using errcode = 'P0001';
  end if;
  delete from public.custom_request_kinds where id = p_id;
  perform public.audit_write(v_company, 'custom_kind.delete', 'custom_kind', p_id::text,
    jsonb_build_object('family', v_kind.family, 'name', v_kind.name));
end;
$$;

revoke all on function public.admin_list_custom_kinds() from public, anon;
revoke all on function public.admin_save_custom_kind(uuid, text, text, boolean, numeric, text, boolean, text, integer) from public, anon;
revoke all on function public.admin_delete_custom_kind(uuid) from public, anon;
grant execute on function public.admin_list_custom_kinds() to authenticated;
grant execute on function public.admin_save_custom_kind(uuid, text, text, boolean, numeric, text, boolean, text, integer) to authenticated;
grant execute on function public.admin_delete_custom_kind(uuid) to authenticated;

-- ---------------------------------------------------------------- C. the balance of a custom leave, and days per employee
-- Same shape as private.leave_balance (non-annual branch). entitled = the employee's own days if he has a row, else the kind's
-- default_days (NULL = unlimited, remaining NULL). 0 is 0 days, never unlimited. An unknown kind is an error, not "unlimited".
create or replace function private.custom_leave_balance(p_employee uuid, p_kind uuid, p_year integer, p_exclude_request uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_entitled numeric;
  v_found boolean;
  v_used numeric;
  v_pending numeric;
begin
  select c.timezone into v_tz
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = p_employee;
  select true, coalesce(l.days, k.default_days) into v_found, v_entitled
  from public.custom_request_kinds k
  left join public.custom_kind_entitlements l on l.kind_id = k.id and l.employee_id = p_employee
  where k.id = p_kind;
  if v_found is not true then
    raise exception 'custom_kind_not_found' using errcode = '22023';
  end if;
  select coalesce(sum(coalesce(r.charged_days, r.days)) filter (where r.status = 'approved'), 0),
         coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pending
  from public.requests r
  where r.employee_id = p_employee and r.request_type = 'leave' and r.custom_kind_id = p_kind
    and extract(year from (r.start_at at time zone v_tz)) = p_year
    and (p_exclude_request is null or r.id <> p_exclude_request);
  return jsonb_build_object(
    'leave_type', 'custom',
    'custom_kind_id', p_kind,
    'entitled', v_entitled,
    'used', v_used,
    'pending', v_pending,
    'remaining', case when v_entitled is null then null else v_entitled - v_used - v_pending end);
end;
$$;
revoke all on function private.custom_leave_balance(uuid, uuid, integer, uuid) from public, anon, authenticated;

-- The employee's own days per leave kind: {"<kind id>": days}. Only overrides are listed.
create or replace function public.admin_get_employee_kind_days(p_employee_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  return coalesce((select jsonb_object_agg(l.kind_id::text, l.days)
                   from public.custom_kind_entitlements l
                   where l.employee_id = p_employee_id and l.company_id = v_company), '{}'::jsonb);
end;
$$;

-- p_days: {"<kind id>": number | null}. Only the given keys change; null removes the employee's own days (back to the default).
-- All or nothing: one refused key changes nothing.
create or replace function public.admin_set_employee_kind_days(p_employee_id uuid, p_days jsonb)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_key text;
  v_val jsonb;
  v_kind uuid;
  v_num numeric;
begin
  if p_days is null or jsonb_typeof(p_days) is distinct from 'object' then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  for v_key, v_val in select * from jsonb_each(p_days) loop
    begin
      v_kind := v_key::uuid;
    exception when invalid_text_representation then
      raise exception 'invalid_input' using errcode = '22023';
    end;
    if not exists (select 1 from public.custom_request_kinds where id = v_kind and company_id = v_company) then
      raise exception 'custom_kind_not_found' using errcode = '22023';
    end if;
    if not exists (select 1 from public.custom_request_kinds where id = v_kind and family = 'leave') then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    if jsonb_typeof(v_val) = 'null' then
      delete from public.custom_kind_entitlements where kind_id = v_kind and employee_id = p_employee_id;
    elsif jsonb_typeof(v_val) = 'number' then
      v_num := (v_val #>> '{}')::numeric;
      if v_num < 0 or v_num > 366 or round(v_num, 1) <> v_num then
        raise exception 'invalid_input' using errcode = '22023';
      end if;
      insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days)
      values (v_company, v_kind, p_employee_id, v_num)
      on conflict (kind_id, employee_id) do update set days = excluded.days;
    else
      raise exception 'invalid_input' using errcode = '22023';
    end if;
  end loop;
  perform public.audit_write(v_company, 'custom_kind.days_set', 'employee', p_employee_id::text,
    jsonb_build_object('days', p_days));
end;
$$;
revoke all on function public.admin_get_employee_kind_days(uuid) from public, anon;
revoke all on function public.admin_set_employee_kind_days(uuid, jsonb) from public, anon;
grant execute on function public.admin_get_employee_kind_days(uuid) to authenticated;
grant execute on function public.admin_set_employee_kind_days(uuid, jsonb) to authenticated;

-- ================================================================ D. approval paths per custom kind
-- The path of a request type (and permission type, or custom kind): the company's steps, or direct manager -> HR.
-- A kind's rows and the plain path never see each other: both branches match custom_kind_id with "is not distinct from".
drop function private.request_chain(uuid, public.request_type, uuid);
create function private.request_chain(p_company uuid, p_type public.request_type, p_permission_type uuid default null, p_custom_kind uuid default null)
returns table (step_order smallint, approver_kind text, approver_employee_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select s.step_order, s.approver_kind, s.approver_employee_id
  from public.approval_steps s
  where s.company_id = p_company and s.request_type = p_type
    and s.permission_type_id is not distinct from p_permission_type
    and s.custom_kind_id is not distinct from p_custom_kind
  union all
  select d.step_order, d.approver_kind, null::uuid
  from (values (1::smallint, 'direct_manager'), (2::smallint, 'hr')) as d (step_order, approver_kind)
  where not exists (select 1 from public.approval_steps s
                    where s.company_id = p_company and s.request_type = p_type
                      and s.permission_type_id is not distinct from p_permission_type
                      and s.custom_kind_id is not distinct from p_custom_kind)
  order by 1
$$;
revoke all on function private.request_chain(uuid, public.request_type, uuid, uuid) from public, anon, authenticated;

-- The paths for the admin screen: leave / other / one per permission type (unchanged) and now one per "other" kind.
-- "customized" lists the request types with their own plain path, so kind rows are left out of it.
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
      from public.approval_steps s
      where s.company_id = v_company and s.request_type <> 'permission' and s.custom_kind_id is null),
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
      from public.permission_types pt where pt.company_id = v_company), '[]'::jsonb),
    'custom_kinds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', k.id, 'name', k.name, 'enabled', k.enabled,
               'customized', exists (select 1 from public.approval_steps s where s.custom_kind_id = k.id),
               'steps', coalesce((
                 select jsonb_agg(jsonb_build_object('step_order', c.step_order, 'kind', c.approver_kind,
                          'approver_employee_id', c.approver_employee_id,
                          'approver_name', (select e.full_name from public.employees e where e.id = c.approver_employee_id))
                        order by c.step_order)
                 from private.request_chain(v_company, 'other', null, k.id) c), '[]'::jsonb))
             order by k.sort_order, k.name)
      from public.custom_request_kinds k where k.company_id = v_company and k.family = 'other'), '[]'::jsonb));
end;
$$;

-- p_steps: [{"kind": "direct_manager"}, {"kind": "specific_employee", "approver_employee_id": "..."}, {"kind": "hr"}]
-- An empty array goes back to the default path. Requests already submitted keep their frozen path.
-- For 'permission', p_permission_type_id says which type; for 'leave' and 'other' it must be null.
-- p_custom_kind_id (new): the path of one "other" kind of this company; only with 'other' and no permission type.
drop function public.admin_set_approval_chain(text, jsonb, uuid);
create function public.admin_set_approval_chain(p_request_type text, p_steps jsonb, p_permission_type_id uuid default null, p_custom_kind_id uuid default null)
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
  v_family text;
begin
  if p_request_type is null or p_request_type not in ('leave', 'permission', 'other')
     or jsonb_typeof(p_steps) is distinct from 'array' or jsonb_array_length(p_steps) > 5
     or (p_request_type = 'permission') <> (p_permission_type_id is not null)
     or (p_custom_kind_id is not null and (p_request_type <> 'other' or p_permission_type_id is not null)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_permission_type_id is not null
     and not exists (select 1 from public.permission_types where id = p_permission_type_id and company_id = v_company) then
    raise exception 'permission_type_not_found' using errcode = '22023';
  end if;
  if p_custom_kind_id is not null then
    select k.family into v_family from public.custom_request_kinds k where k.id = p_custom_kind_id and k.company_id = v_company;
    if not found then
      raise exception 'custom_kind_not_found' using errcode = '22023';
    end if;
    if v_family <> 'other' then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
  end if;
  delete from public.approval_steps
   where company_id = v_company and request_type = p_request_type::public.request_type
     and permission_type_id is not distinct from p_permission_type_id
     and custom_kind_id is not distinct from p_custom_kind_id;
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
    insert into public.approval_steps (company_id, request_type, step_order, approver_kind, approver_employee_id, permission_type_id, custom_kind_id)
    values (v_company, p_request_type::public.request_type, v_order, v_kind, v_emp, p_permission_type_id, p_custom_kind_id);
  end loop;
  perform public.audit_write(v_company, 'approval_chain.set', 'company', v_company::text,
    jsonb_build_object('request_type', p_request_type, 'permission_type_id', p_permission_type_id,
                       'custom_kind_id', p_custom_kind_id, 'steps', p_steps));
exception
  when invalid_text_representation then
    raise exception 'invalid_input' using errcode = '22023';
end;
$$;
revoke all on function public.admin_set_approval_chain(text, jsonb, uuid, uuid) from public, anon;
revoke all on function public.admin_get_approval_chains() from public, anon;
grant execute on function public.admin_set_approval_chain(text, jsonb, uuid, uuid) to authenticated;
grant execute on function public.admin_get_approval_chains() to authenticated;

-- ================================================================ E. employee: submit (phase 24: a custom leave, a custom "other" request)
-- The phase 18a function with one more parameter. Only the lines for the custom kind are new; the old 10-argument
-- calls still resolve to this function (the new parameter has a default).
drop function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid);
create function public.employee_submit_request(p_request_key uuid, p_type text, p_leave_type text DEFAULT NULL::text, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date, p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_reason text DEFAULT NULL::text, p_dry_run boolean DEFAULT false, p_permission_type_id uuid DEFAULT NULL::uuid, p_custom_kind_id uuid DEFAULT NULL::uuid)
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
  v_kind public.custom_request_kinds;
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

  -- A custom kind (phase 24) of my company: it must exist, fit the request type and be switched on.
  if p_custom_kind_id is not null then
    if v_type not in ('leave', 'other') then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    select * into v_kind from public.custom_request_kinds where id = p_custom_kind_id and company_id = me.company_id;
    if not found then
      raise exception 'custom_kind_not_found' using errcode = '22023';
    end if;
    if v_kind.family <> p_type then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    if not v_kind.enabled then
      raise exception 'custom_kind_disabled' using errcode = '22023';
    end if;
  end if;

  if v_type = 'leave' then
    if v_kind.id is not null then
      p_leave_type := 'custom';  -- the kind decides; whatever leave type the app sent is ignored
    end if;
    if (v_kind.id is null and (p_leave_type is null or p_leave_type not in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid')))
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
    if v_kind.id is not null and (
         (v_kind.gender = 'female' and coalesce(v_emp.gender, '') <> 'female')
         or (v_kind.gender = 'male' and coalesce(v_emp.gender, '') <> 'male')) then
      raise exception 'kind_gender_mismatch' using errcode = '22023';
    end if;
    if v_kind.id is not null and v_kind.reason_required and v_reason is null and not p_dry_run then
      raise exception 'reason_required' using errcode = '22023';
    end if;
    v_days := private.leave_days(me.employee_id, p_start_date, p_end_date);
    if v_days = 0 then
      raise exception 'no_working_days' using errcode = 'P0001';
    end if;
    -- Annual leave: what was earned up to the first day of the leave. More than the balance needs a reason (HR decides).
    if v_kind.id is not null then
      v_bal := private.custom_leave_balance(me.employee_id, v_kind.id, extract(year from p_start_date)::int);
    else
      v_bal := private.leave_balance(me.employee_id, p_leave_type, extract(year from p_start_date)::int, null, p_start_date);
    end if;
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
    if v_kind.id is not null and v_kind.date_mode = 'none' then
      -- a kind without dates: the request is for today (company time zone), whatever dates were sent
      v_start := v_today::timestamp at time zone me.timezone;
      v_end := (v_today + 1)::timestamp at time zone me.timezone;
    else
      if v_kind.id is not null and v_kind.date_mode = 'single' then
        p_end_date := p_start_date;  -- one day: an end date that was sent is ignored
      end if;
      if p_start_date is null or p_end_date is null or p_end_date < p_start_date
         or p_end_date - p_start_date > 365 or p_start_date < v_today - 30 or p_start_date > v_today + 365 then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      v_start := p_start_date::timestamp at time zone me.timezone;
      v_end := (p_end_date + 1)::timestamp at time zone me.timezone;
    end if;
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
      'balance', v_bal, 'permission', v_perm, 'over_balance', v_over, 'custom_kind_id', v_kind.id);
  end if;

  insert into public.requests (employee_id, request_type, leave_type, permission_type_id, status, start_at, end_at,
                               reason, days, minutes, request_key, custom_kind_id)
  values (me.employee_id, v_type, case when v_type = 'leave' then p_leave_type end, v_pt.id, 'pending',
          v_start, v_end, v_reason, v_days, v_minutes, p_request_key, v_kind.id)
  returning id into v_id;

  -- Resolve and freeze the approvers.
  for v_step in select * from private.request_chain(me.company_id, v_type, v_pt.id, case when v_type = 'other' then v_kind.id end) loop
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
revoke all on function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid, uuid) from public, anon;
grant execute on function public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean, uuid, uuid) to authenticated;

-- ================================================================ G. what the app and the people see
-- The request as the app shows it: with the kind id, its live name and its date mode.
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
    'custom_kind_id', r.custom_kind_id, 'kind_name', k.name, 'date_mode', k.date_mode,
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
  left join public.custom_request_kinds k on k.id = r.custom_kind_id
  where r.id = p_request
$$;
revoke all on function private.request_json(uuid) from public, anon, authenticated;

-- The one-line summary used by notifications: a custom leave and a custom other request read by their kind's name.
create or replace function private.request_summary(p_request uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case r.request_type
    when 'leave' then
      -- a kind named «إجازة حج» reads «إجازة حج», not «إجازة إجازة حج» (the panel and the app do the same)
      case when r.leave_type = 'custom' and k.name like 'إجازة%' then '' else 'إجازة ' end
      || case r.leave_type when 'annual' then 'سنوية' when 'sick' then 'مرضية' when 'emergency' then 'طارئة'
                                    when 'marriage' then 'زواج' when 'maternity' then 'أمومة' when 'unpaid' then 'بدون راتب'
                                    when 'custom' then coalesce(k.name, '') else '' end
      || ' · ' || private.days_text(r.days) || ' · '
      || to_char(r.start_at at time zone c.timezone, 'DD/MM')
      || case when (r.end_at - interval '1 second') at time zone c.timezone >= (r.start_at at time zone c.timezone)::date + 1
              then ' – ' || to_char((r.end_at - interval '1 second') at time zone c.timezone, 'DD/MM') else '' end
    when 'permission' then
      'إذن: ' || coalesce(pt.name, '') || ' · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM HH24:MI')
      || '–' || to_char(r.end_at at time zone c.timezone, 'HH24:MI')
    else
      coalesce(k.name, 'طلب آخر') || ' · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM')
  end
  from public.requests r
  join public.companies c on c.id = r.company_id
  left join public.permission_types pt on pt.id = r.permission_type_id
  left join public.custom_request_kinds k on k.id = r.custom_kind_id
  where r.id = p_request
$$;
revoke all on function private.request_summary(uuid) from public, anon, authenticated;

-- Final approval: a custom leave is checked against its own kind (phase 18a logic, one more branch).
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
        if v_req.leave_type = 'custom' then
          -- phase 24: a custom leave is checked against its own kind (not "unlimited" by accident)
          v_bal := private.custom_leave_balance(v_req.employee_id, v_req.custom_kind_id,
                     extract(year from (v_req.start_at at time zone v_tz))::int, v_req.id);
        else
          v_bal := private.leave_balance(v_req.employee_id, v_req.leave_type,
                     extract(year from (v_req.start_at at time zone v_tz))::int, v_req.id);
        end if;
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

-- The employee's overview: unchanged keys, plus the kinds this employee may use, each with its balance (leave kinds).
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
    'custom_kinds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', k.id, 'family', k.family, 'name', k.name, 'sort_order', k.sort_order, 'gender', k.gender,
               'reason_required', k.reason_required, 'date_mode', k.date_mode,
               'balance', case when k.family = 'leave'
                               then private.custom_leave_balance(me.employee_id, k.id, extract(year from v_today)::int) end)
             order by k.sort_order, k.name)
      from public.custom_request_kinds k
      where k.company_id = me.company_id and k.enabled
        and (k.family = 'other' or k.gender = 'all' or k.gender = v_emp.gender)), '[]'::jsonb),
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
