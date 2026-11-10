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
