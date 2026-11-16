-- Rollback of phase 28 (custom permissions for system admins).
--   * Every custom admin becomes a plain viewer (the viewer list is part of the custom level, so nobody gains anything; only his groups are lost).
--   * The functions changed by phase 28 get their phase 26 text back, the two new functions, the two helpers and the three tables are dropped,
--     and the role check goes back to the five values of phase 26.
--   * What stays: the audit rows 'admin.role_changed' / 'admin.grants_changed' already written (history).
--   Run with psql -1 (one transaction).
update public.company_members set role = 'viewer' where role = 'custom_admin';

-- ---------------------------------------------------------------- phase 26 texts, copied unchanged from 20261115100000_phase26_admin_roles.sql
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
  where m.user_id = (select auth.uid()) and m.role in ('hr_admin', 'supervisor', 'viewer')
$$;
revoke all on function private.limited_admin() from public, anon, authenticated;

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
    -- Not an owner. A limited level passes only inside an admin function that is listed for his level.
    select l.company_id, l.role into v_company, v_role from private.limited_admin() l;
    if v_company is null then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    -- The function the client called is the OUTERMOST admin_* frame of the call stack (the last one in the text).
    -- Functions with a fixed search_path are printed with their schema, the others without it.
    get diagnostics v_ctx = pg_context;
    select t.m[1] into v_rpc
    from regexp_matches(v_ctx, 'PL/pgSQL function (?:public\.)?(admin_[a-z0-9_]+)\(', 'g') with ordinality as t(m, n)
    order by t.n desc
    limit 1;
    if v_rpc is null or not exists (select 1 from private.admin_role_rpcs r where r.role = v_role and r.rpc = v_rpc) then
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
    -- phase 26. admin_role: the level that works now (null = none). permissions: the admin functions of a limited level (null for the owner = all).
    'admin_role', case when public.admin_company_id() is not null then 'company_admin' else (select l.role from private.limited_admin() l) end,
    'is_panel_user', public.admin_company_id() is not null or exists (select 1 from private.limited_admin()),
    'permissions', case when public.admin_company_id() is not null then null
                        else (select jsonb_agg(r.rpc order by r.rpc) from private.admin_role_rpcs r
                              join private.limited_admin() l on l.role = r.role) end
  )
  from (select 1) one
  left join public.company_members m on m.user_id = (select auth.uid())
  left join public.companies c on c.id = m.company_id
$$;

-- ---------------------------------------------------------------- the two patched functions go back (exact inverse of the phase 28 patches)
do $patch$
declare
  v_def text := pg_get_functiondef('public.admin_set_admin_role(uuid, text)'::regprocedure);
  v_new constant text := '  update public.company_members set role = p_role' || chr(10) || '  where user_id = p_employee_id and company_id = v_company;' || chr(10);
  v_extra constant text := '  delete from private.admin_grants where user_id = p_employee_id;' || chr(10);
begin
  if position(v_new || v_extra in v_def) > 0 then
    execute replace(v_def, v_new || v_extra, v_new);
  end if;
end
$patch$;
do $patch$
declare
  v_def text := pg_get_functiondef('public.admin_delete_employee(uuid, text)'::regprocedure);
begin
  if position('''custom_admin''' in v_def) > 0 then
    execute replace(v_def, ', ''custom_admin'')', ')');
  end if;
end
$patch$;

-- ---------------------------------------------------------------- drop what phase 28 added
drop function if exists public.admin_set_admin_grants(uuid, text[]);
drop function if exists public.admin_list_admin_grants();
drop function if exists private.admin_may_call(uuid, uuid, text, text);
drop function if exists private.admin_permissions_of(uuid, uuid, text);
drop table if exists private.admin_grants;
drop table if exists private.admin_group_rpcs;
drop table if exists private.admin_groups;

alter table public.company_members drop constraint if exists company_members_role_check;
alter table public.company_members add constraint company_members_role_check
  check (role in ('company_admin', 'hr_admin', 'supervisor', 'viewer', 'employee'));
