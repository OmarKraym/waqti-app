-- Phase 28: custom permissions for system admins.
--   Phase 26 gave three fixed admin levels. This phase adds a fourth level, 'custom_admin', whose rights the OWNER chooses per person:
--     custom admin = the read-only list of the viewer level (always) + the functions of the groups the owner ticked for him.
--   The groups (private.admin_groups / private.admin_group_rpcs, data only; a new function is added to a group with one insert):
--     decisions   requests, reviews and leave decisions (the supervisor list of phase 26)
--     employees   everything the employee form calls: the file (it holds the salary), grace, punch windows, kind days, leave year, devices, manager
--     workplace   the geofence of an employee and his location policy
--     punches     manual punch and, new, editing the time of a movement (phase 27)
--   Nothing is granted that the HR admin level of phase 26 does not already have, except admin_edit_punch. Never in a group (owner only, forever):
--   managing admins and levels, deleting employees, company name and settings, payroll, holidays and every other function not listed here.
--   * public.admin_set_admin_grants(employee, groups[])  owner only, audited: makes the person a custom admin with exactly these groups
--     (also from employee, from a fixed level or from owner), or replaces his groups. public.admin_list_admin_grants() lists them (owner only).
--   * require_company_admin() (the gate of every admin_* function) asks private.admin_may_call(): the three fixed levels read
--     private.admin_role_rpcs exactly as before; a custom admin reads the viewer rows + the rows of his groups IN HIS OWN COMPANY.
--     The owner path, the must_change_password check and the "outermost admin_* frame" rule are unchanged.
--   * my_admin_context() returns admin_role = 'custom_admin' and his permission list (the panel hides what he cannot call).
--   * admin_set_admin_role() deletes the groups of a person who leaves the custom level (it still refuses to set 'custom_admin' itself).
--   * admin_delete_employee() also refuses an account that holds the custom level, like the other levels.
--   Grant rows of a person who is not a custom admin, or of another company, are inert (the gate joins on both) and are removed with the
--   account (foreign keys). A custom admin signs in with a password only, cannot touch accounts that hold a level, and loses everything when
--   his employee or his company is deactivated: all of that is phase 26 behaviour that already keys on "role <> employee" or on limited_admin().
-- Rollback: 20261116120000_phase28_admin_custom_permissions_ROLLBACK.sql (custom admins become viewers: nothing is gained, only groups are lost)

do $guard$
begin
  if to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.my_admin_context()') is null
     or to_regprocedure('private.limited_admin()') is null
     or to_regclass('private.admin_role_rpcs') is null
     or to_regprocedure('public.admin_set_admin_role(uuid, text)') is null
     or to_regprocedure('public.admin_delete_employee(uuid, text)') is null
     or to_regprocedure('private.working_admin_count(uuid, uuid)') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null then
    raise exception 'phase28: the admin levels phase (26) must be applied first';
  end if;
  if to_regprocedure('public.admin_edit_punch(uuid, timestamp with time zone, text)') is null then
    raise exception 'phase28: the edit-a-movement phase (27) must be applied first';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- the role value
alter table public.company_members drop constraint if exists company_members_role_check;
alter table public.company_members add constraint company_members_role_check
  check (role in ('company_admin', 'hr_admin', 'supervisor', 'viewer', 'custom_admin', 'employee'));

-- ---------------------------------------------------------------- the catalogue and the grants (private)
create table if not exists private.admin_groups (
  group_key text primary key
);
create table if not exists private.admin_group_rpcs (
  group_key text not null references private.admin_groups (group_key),
  rpc       text not null,
  primary key (group_key, rpc)
);
create table if not exists private.admin_grants (
  company_id uuid not null references public.companies (id) on delete cascade,
  user_id    uuid not null references public.employees (id) on delete cascade,
  group_key  text not null references private.admin_groups (group_key),
  granted_by uuid,
  granted_at timestamptz not null default now(),
  primary key (user_id, group_key)
);
create index if not exists admin_grants_company_idx on private.admin_grants (company_id);
revoke all on table private.admin_groups, private.admin_group_rpcs, private.admin_grants from public, anon, authenticated;

insert into private.admin_groups (group_key) values ('decisions'), ('employees'), ('workplace'), ('punches') on conflict do nothing;
insert into private.admin_group_rpcs (group_key, rpc) values
  -- decisions = the functions only the supervisor level adds to the viewer list (phase 26)
  ('decisions', 'admin_review_queue'), ('decisions', 'admin_decide_request'), ('decisions', 'admin_decide_leave_day'),
  ('decisions', 'admin_resolve_leave_conflict'), ('decisions', 'admin_resolve_review'), ('decisions', 'admin_dismiss_missing_checkin'),
  ('decisions', 'admin_get_leave_years'), ('decisions', 'admin_get_employee_kind_days'), ('decisions', 'admin_get_employee_grace'),
  -- employees: everything the employee form calls: the file (salary included), grace, punch windows, kind days, leave year, devices, manager.
  -- The three reads are repeated here on purpose (a write never loses the read it needs).
  ('employees', 'admin_get_employee_profile'), ('employees', 'admin_save_employee_profile'), ('employees', 'admin_update_employee'),
  ('employees', 'admin_set_employee_manager'), ('employees', 'admin_set_leave_year'), ('employees', 'admin_set_employee_kind_days'),
  ('employees', 'admin_set_employee_grace'), ('employees', 'admin_set_employee_punch_windows'),
  ('employees', 'admin_list_device_bindings'), ('employees', 'admin_remove_device'),
  ('employees', 'admin_get_leave_years'), ('employees', 'admin_get_employee_kind_days'), ('employees', 'admin_get_employee_grace'),
  -- workplace: the geofence of an employee and his location policy
  ('workplace', 'admin_set_geofence'), ('workplace', 'admin_use_location_geofence'), ('workplace', 'admin_set_employee_location_policy'),
  -- punches: add (phase 20) and edit the time (phase 27)
  ('punches', 'admin_add_punch'), ('punches', 'admin_edit_punch')
on conflict do nothing;

-- ---------------------------------------------------------------- the two questions the gate and the panel ask (private)
-- May this person (with this role, in this company) call this admin function?
create or replace function private.admin_may_call(p_user uuid, p_company uuid, p_role text, p_rpc text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_role in ('hr_admin', 'supervisor', 'viewer') then
      exists (select 1 from private.admin_role_rpcs r where r.role = p_role and r.rpc = p_rpc)
    when p_role = 'custom_admin' then
      exists (select 1 from private.admin_role_rpcs r where r.role = 'viewer' and r.rpc = p_rpc)
      or exists (select 1
                 from private.admin_grants g
                 join private.admin_group_rpcs gr on gr.group_key = g.group_key
                 where g.user_id = p_user and g.company_id = p_company and gr.rpc = p_rpc)
    else false
  end
$$;
revoke all on function private.admin_may_call(uuid, uuid, text, text) from public, anon, authenticated;

-- Every admin function this person may call (the list the panel reads).
create or replace function private.admin_permissions_of(p_user uuid, p_company uuid, p_role text)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_role in ('hr_admin', 'supervisor', 'viewer') then
      (select coalesce(array_agg(r.rpc order by r.rpc), '{}') from private.admin_role_rpcs r where r.role = p_role)
    when p_role = 'custom_admin' then
      (select coalesce(array_agg(x.rpc order by x.rpc), '{}')
       from (select r.rpc from private.admin_role_rpcs r where r.role = 'viewer'
             union
             select gr.rpc from private.admin_grants g
             join private.admin_group_rpcs gr on gr.group_key = g.group_key
             where g.user_id = p_user and g.company_id = p_company) x)
    else null
  end
$$;
revoke all on function private.admin_permissions_of(uuid, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- the signed-in user's limited level (custom admins included)
create or replace function private.limited_admin()
returns table (company_id uuid, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.company_id, m.role
  from public.company_members m
  join public.companies c on c.id = m.company_id and c.is_active
  join public.employees e on e.id = m.user_id and e.is_active
  where m.user_id = (select auth.uid()) and m.role in ('hr_admin', 'supervisor', 'viewer', 'custom_admin')
$$;
revoke all on function private.limited_admin() from public, anon, authenticated;

-- ---------------------------------------------------------------- the gate of every admin_* function (one line differs from phase 26)
create or replace function public.require_company_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.admin_company_id();
  v_role text;
  v_ctx text;
  v_rpc text;
begin
  if v_company is null then
    -- Not an owner. A limited level passes only inside an admin function that is listed for his level (or for his groups).
    select l.company_id, l.role into v_company, v_role from private.limited_admin() l;
    if v_company is null then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    -- The function the client called is the OUTERMOST admin_* frame of the call stack (the last one in the text).
    -- Functions with a fixed search_path are printed with their schema, the others without it.
    get diagnostics v_ctx = pg_context;
    select t.m[1] into v_rpc
    from regexp_matches(v_ctx, 'PL/pgSQL function (?:public[.])?(admin_[a-z0-9_]+)[(]', 'g') with ordinality as t(m, n)
    order by t.n desc
    limit 1;
    if v_rpc is null or not private.admin_may_call((select auth.uid()), v_company, v_role, v_rpc) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;
  -- A temporary password (shown to whoever created the account) must be replaced first.
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) then
    raise exception 'must_change_password' using errcode = '42501';
  end if;
  return v_company;
end;
$$;

-- ---------------------------------------------------------------- the context of the signed-in user
create or replace function public.my_admin_context()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', (select auth.uid()),
    'company_id', m.company_id,
    'company_name', c.name,
    'company_role', m.role,
    'is_company_admin', public.admin_company_id() is not null,
    'is_platform_admin', public.is_platform_admin(),
    -- admin_role: the level that works now (null = none). permissions: the admin functions of a limited level or custom admin (null for the owner = all).
    'admin_role', case when public.admin_company_id() is not null then 'company_admin' else (select l.role from private.limited_admin() l) end,
    'is_panel_user', public.admin_company_id() is not null or exists (select 1 from private.limited_admin()),
    'permissions', case when public.admin_company_id() is not null then null
                        else (select to_jsonb(private.admin_permissions_of((select auth.uid()), l.company_id, l.role))
                              from private.limited_admin() l) end
  )
  from (select 1) one
  left join public.company_members m on m.user_id = (select auth.uid())
  left join public.companies c on c.id = m.company_id
$$;

-- ---------------------------------------------------------------- list and choose the groups (owner only: in no list and in no group)
create or replace function public.admin_list_admin_grants()
returns table (user_id uuid, group_key text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select g.user_id, g.group_key
  from private.admin_grants g
  join public.company_members m on m.user_id = g.user_id and m.company_id = g.company_id and m.role = 'custom_admin'
  where g.company_id = v_company
  order by g.user_id, g.group_key;
end;
$$;
revoke all on function public.admin_list_admin_grants() from public, anon;
grant execute on function public.admin_list_admin_grants() to authenticated;

create or replace function public.admin_set_admin_grants(p_employee_id uuid, p_groups text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
  v_groups text[];
  v_old text[] := '{}';
  v_emp record;
begin
  select coalesce(array_agg(distinct g order by g), '{}') into v_groups from unnest(coalesce(p_groups, '{}')) g where g is not null;
  if cardinality(v_groups) = 0 then
    raise exception 'no_groups' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(v_groups) g where not exists (select 1 from private.admin_groups x where x.group_key = g)) then
    raise exception 'invalid_group' using errcode = 'P0001';
  end if;
  -- One change of admin levels at a time per company (the lock of phase 16 and of admin_set_admin_role).
  perform pg_advisory_xact_lock(hashtextextended('waqti.admins:' || v_company::text, 0));
  -- The caller may have lost the role while this call was waiting for the lock.
  if public.admin_company_id() is distinct from v_company then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_employee_id = (select auth.uid()) then
    raise exception 'cannot_change_self' using errcode = 'P0001';
  end if;

  select e.full_name, e.employee_number, e.is_active, m.role
    into v_emp
  from public.employees e
  join public.company_members m on m.user_id = e.id and m.company_id = e.company_id
  where e.id = p_employee_id and e.company_id = v_company
  for update of m;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if not v_emp.is_active then
    raise exception 'employee_inactive' using errcode = 'P0001';
  end if;
  if v_emp.role = 'custom_admin' then
    select coalesce(array_agg(g.group_key order by g.group_key), '{}') into v_old
    from private.admin_grants g where g.user_id = p_employee_id and g.company_id = v_company;
    if v_old = v_groups then
      raise exception 'no_change' using errcode = 'P0001';
    end if;
  end if;
  if v_emp.role = 'company_admin' and private.working_admin_count(v_company, p_employee_id) < 1 then
    raise exception 'last_admin' using errcode = 'P0001';
  end if;

  update public.company_members set role = 'custom_admin'
  where user_id = p_employee_id and company_id = v_company;
  delete from private.admin_grants where user_id = p_employee_id;
  insert into private.admin_grants (company_id, user_id, group_key, granted_by)
  select v_company, p_employee_id, g, (select auth.uid()) from unnest(v_groups) g;

  if v_emp.role <> 'custom_admin' then
    perform public.audit_write(v_company, 'admin.role_changed', 'employee', p_employee_id::text,
      jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name, 'from', v_emp.role, 'to', 'custom_admin'));
    -- Keep the phase 16 records true for owners (its list shows "since" from admin.added).
    if v_emp.role = 'company_admin' then
      perform public.audit_write(v_company, 'admin.removed', 'employee', p_employee_id::text,
        jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name));
    end if;
  end if;
  perform public.audit_write(v_company, 'admin.grants_changed', 'employee', p_employee_id::text,
    jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name, 'from', to_jsonb(v_old), 'to', to_jsonb(v_groups)));
  return jsonb_build_object('employee_id', p_employee_id, 'full_name', v_emp.full_name, 'employee_number', v_emp.employee_number,
                            'role', 'custom_admin', 'previous', v_emp.role, 'groups', to_jsonb(v_groups));
end;
$$;
revoke all on function public.admin_set_admin_grants(uuid, text[]) from public, anon;
grant execute on function public.admin_set_admin_grants(uuid, text[]) to authenticated;

-- ---------------------------------------------------------------- the two existing functions that get one small change each
-- Each text is read from the database and changed in exactly one place; the run stops (and nothing is kept) when the place is not found
-- exactly once. CREATE OR REPLACE keeps the grants.
-- (1) admin_set_admin_role: a person who leaves the custom level loses his groups.
do $patch$
declare
  v_def text := pg_get_functiondef('public.admin_set_admin_role(uuid, text)'::regprocedure);
  v_old constant text := '  update public.company_members set role = p_role' || chr(10) || '  where user_id = p_employee_id and company_id = v_company;' || chr(10);
begin
  if position('private.admin_grants' in v_def) > 0 then
    return;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) <> length(v_old) then
    raise exception 'phase28: admin_set_admin_role does not contain the role update exactly once';
  end if;
  execute replace(v_def, v_old, v_old || '  delete from private.admin_grants where user_id = p_employee_id;' || chr(10));
end
$patch$;
-- (2) admin_delete_employee: an account that holds the custom level cannot be deleted before the level is taken away.
do $patch$
declare
  v_def text := pg_get_functiondef('public.admin_delete_employee(uuid, text)'::regprocedure);
  v_old constant text := 'if v_role in (''company_admin'', ''hr_admin'', ''supervisor'', ''viewer'') then';
  v_new constant text := 'if v_role in (''company_admin'', ''hr_admin'', ''supervisor'', ''viewer'', ''custom_admin'') then';
begin
  if position('''custom_admin''' in v_def) > 0 then
    return;
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) <> length(v_old) then
    raise exception 'phase28: admin_delete_employee does not contain the admin check exactly once';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;
