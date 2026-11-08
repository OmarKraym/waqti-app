-- Phase 21: delete a work place, delete an employee (nothing is erased: a "deleted" row stays, hidden from the lists).
--   * work_locations.deleted_at, employees.deleted_at (null = live). A deleted employee is also inactive (check constraint), so he
--     cannot punch, cannot reach a usable state (require_active_employee) and cannot be made an admin.
--   * The unique place-name index only covers live places: the name of a deleted place can be added again.
--   * A trigger keeps people off a deleted place: nobody is moved into it, and nobody whose place was deleted becomes active again
--     before he gets a live place. It locks the place row (FOR KEY SHARE), so it waits for a delete in progress and then sees it.
--   * public.admin_delete_work_location(place, move_to) -> {deleted: true, moved: n}
--       not_found | has_employees (active employees there and no target) | invalid_target (itself, deleted, another company, unknown)
--       Active employees are moved to the target and get its geofence (same copy as when a profile is saved); inactive ones keep the
--       old place (history). Both place rows are locked first (in id order), so a move into the place at the same moment is seen.
--   * public.admin_delete_employee(employee, typed_name) -> {deleted: true}
--       not_found | self_delete | is_admin | name_mismatch | open_session | pending_requests | has_reports | is_approver
--       In that order. The typed name must equal his name after trimming, collapsing spaces and Unicode normalisation (NFC).
--       It sets deleted_at and is_active = false, removes his phone binding (admin_remove_device) and his push subscriptions, and is
--       audited ('employee.delete'). His attendance, requests and audit rows are not touched. His number and e-mail stay reserved.
--   * admin_list_work_locations: + active_count, hides deleted places, employees_count counts people who are not deleted.
--     admin_list_employees: hides deleted employees (same columns). platform_list_companies: counts people who are not deleted.
--     admin_add_work_location: re-created for the partial index (the conflict target needs its WHERE).
-- Rollback: 20261109100000_phase21_workplaces_delete_employee_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regprocedure('public.admin_remove_device(uuid)') is null
     or to_regprocedure('public.sync_employee_location_geofence(uuid, boolean)') is null
     or to_regprocedure('public.admin_list_employees()') is null
     or to_regprocedure('public.admin_list_work_locations()') is null
     or to_regprocedure('public.admin_add_work_location(text)') is null
     or to_regprocedure('public.platform_list_companies()') is null
     or to_regclass('public.attendance_sessions') is null
     or to_regclass('public.approval_steps') is null
     or to_regclass('public.push_subscriptions') is null then
    raise exception 'phase 21 needs the earlier phases (admin lists, device removal, geofence sync, approval chains, push)';
  end if;
end
$guard$;

-- ---------------------------------------------------------------------------------------------------------------- columns
alter table public.work_locations add column if not exists deleted_at timestamptz;
alter table public.employees add column if not exists deleted_at timestamptz;
alter table public.employees drop constraint if exists employees_deleted_inactive_chk;
alter table public.employees add constraint employees_deleted_inactive_chk check (deleted_at is null or not is_active);

drop index if exists public.work_locations_name_uidx;
create unique index work_locations_name_uidx on public.work_locations (company_id, lower(btrim(name))) where deleted_at is null;

-- ---------------------------------------------------------------------------------------------------------------- the guard trigger
create or replace function private.guard_deleted_location() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_deleted timestamptz;
begin
  if new.work_location_id is null then
    return new;
  end if;
  -- only when the place is chosen, changed, or the employee becomes active again
  if tg_op = 'UPDATE' and new.work_location_id is not distinct from old.work_location_id and not (new.is_active and not old.is_active) then
    return new;
  end if;
  -- FOR KEY SHARE: waits for a delete of that place that has not committed yet, and then reads the row as the delete left it
  select w.deleted_at into v_deleted from public.work_locations w where w.id = new.work_location_id for key share;
  if v_deleted is not null then
    raise exception 'invalid_work_location' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function private.guard_deleted_location() from public, anon, authenticated;

drop trigger if exists employees_guard_deleted_location on public.employees;
create trigger employees_guard_deleted_location
  before insert or update of work_location_id, is_active on public.employees
  for each row execute function private.guard_deleted_location();

-- ---------------------------------------------------------------------------------------------------------------- places
create or replace function public.admin_add_work_location(p_name text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
begin
  if length(v_name) not between 1 and 100 then
    raise exception 'invalid_location_name' using errcode = '22023';
  end if;

  insert into public.work_locations (company_id, name) values (v_company, v_name)
  on conflict (company_id, (lower(btrim(name)))) where deleted_at is null do nothing
  returning id into v_id;

  if v_id is null then
    select w.id into v_id from public.work_locations w
    where w.company_id = v_company and w.deleted_at is null and lower(btrim(w.name)) = lower(v_name);
  else
    perform public.audit_write(v_company, 'work_location.add', 'work_location', v_id::text, jsonb_build_object('name', v_name));
  end if;
  return v_id;
end;
$$;
revoke all on function public.admin_add_work_location(text) from public, anon;
grant execute on function public.admin_add_work_location(text) to authenticated;

drop function if exists public.admin_list_work_locations();
create function public.admin_list_work_locations()
returns table(id uuid, name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric,
              employees_count bigint, active_count bigint)
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    w.id, w.name,
    extensions.st_y(w.geofence_center::extensions.geometry), extensions.st_x(w.geofence_center::extensions.geometry),
    w.geofence_radius_meters,
    (select count(*) from public.employees e where e.work_location_id = w.id and e.company_id = v_company and e.deleted_at is null),
    (select count(*) from public.employees e where e.work_location_id = w.id and e.company_id = v_company and e.deleted_at is null and e.is_active)
  from public.work_locations w
  where w.company_id = v_company and w.deleted_at is null
  order by w.name;
end;
$$;
revoke all on function public.admin_list_work_locations() from public, anon;
grant execute on function public.admin_list_work_locations() to authenticated;

create or replace function public.admin_delete_work_location(p_location_id uuid, p_move_to uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text;
  v_active int;
  v_moved int := 0;
  v_emp uuid;
begin
  -- Lock the place (and the target) first, in id order: an employee being moved in, or another delete of the same place, holds
  -- its lock until it commits. We wait, and what we read next is what they left.
  perform 1 from public.work_locations w
  where w.company_id = v_company and w.id in (p_location_id, p_move_to)
  order by w.id for update;

  select w.name into v_name from public.work_locations w
  where w.id = p_location_id and w.company_id = v_company and w.deleted_at is null;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if p_move_to is not null and (p_move_to = p_location_id or not exists (
       select 1 from public.work_locations w where w.id = p_move_to and w.company_id = v_company and w.deleted_at is null)) then
    raise exception 'invalid_target' using errcode = 'P0001';
  end if;

  select count(*) into v_active from public.employees e
  where e.work_location_id = p_location_id and e.company_id = v_company and e.is_active and e.deleted_at is null;
  if v_active > 0 and p_move_to is null then
    raise exception 'has_employees' using errcode = 'P0001';
  end if;

  if v_active > 0 then
    for v_emp in
      select e.id from public.employees e
      where e.work_location_id = p_location_id and e.company_id = v_company and e.is_active and e.deleted_at is null
      order by e.id for update
    loop
      update public.employees set work_location_id = p_move_to where id = v_emp;
      perform public.sync_employee_location_geofence(v_emp, false);
      v_moved := v_moved + 1;
    end loop;
  end if;

  update public.work_locations set deleted_at = now() where id = p_location_id;
  perform public.audit_write(v_company, 'work_location.delete', 'work_location', p_location_id::text,
    jsonb_build_object('name', v_name, 'moved', v_moved, 'moved_to', p_move_to));
  return jsonb_build_object('deleted', true, 'moved', v_moved);
end;
$$;
revoke all on function public.admin_delete_work_location(uuid, uuid) from public, anon;
grant execute on function public.admin_delete_work_location(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------- employees
create or replace function public.admin_list_employees()
returns table(id uuid, email text, full_name text, employee_number text, department text, is_active boolean, geofence_required boolean,
              created_at timestamp with time zone, geofence_id uuid, geofence_name text, geofence_lat double precision,
              geofence_lng double precision, geofence_radius_meters numeric, job_title text, gender text, birth_date date,
              hire_date date, work_location_id uuid, work_location_name text, geofence_inherited boolean, location_policy text,
              outside_action text, has_device boolean)
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    e.id, u.email::text, e.full_name, e.employee_number, e.department, e.is_active,
    e.geofence_required, e.created_at, g.id, g.name,
    extensions.st_y(g.center::extensions.geometry), extensions.st_x(g.center::extensions.geometry), g.radius_meters,
    e.job_title, e.gender, e.birth_date, e.hire_date, e.work_location_id,
    wl.name, (g.source_location_id is not null),
    e.location_policy, e.outside_action,
    exists (select 1 from public.webauthn_credentials wc where wc.employee_id = e.id)
  from public.employees e
  join auth.users u on u.id = e.id
  left join public.work_locations wl on wl.id = e.work_location_id and wl.company_id = v_company
  left join lateral (
    select x.* from public.employee_geofences x
    where x.employee_id = e.id and x.company_id = v_company and x.is_active
      and x.valid_from <= now() and (x.valid_until is null or x.valid_until > now())
    order by x.created_at desc limit 1
  ) g on true
  where e.company_id = v_company and e.deleted_at is null
  order by e.created_at desc;
end;
$$;
revoke all on function public.admin_list_employees() from public, anon;
grant execute on function public.admin_list_employees() to authenticated;

create or replace function public.admin_delete_employee(p_employee_id uuid, p_confirm_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_emp record;
  v_role text;
  v_typed text;
  v_real text;
begin
  -- The employee row first (as the punch does): a second delete of him waits here and then finds him gone.
  select e.full_name, e.employee_number into v_emp
  from public.employees e
  where e.id = p_employee_id and e.company_id = v_company and e.deleted_at is null
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if p_employee_id = (select auth.uid()) then
    raise exception 'self_delete' using errcode = 'P0001';
  end if;
  -- His membership row is locked too: an admin promotion of him that is still in progress is waited for, and then seen.
  select m.role into v_role from public.company_members m
  where m.user_id = p_employee_id and m.company_id = v_company
  for update;
  if v_role = 'company_admin' then
    raise exception 'is_admin' using errcode = 'P0001';
  end if;

  v_typed := normalize(btrim(regexp_replace(coalesce(p_confirm_name, ''), '[[:space:]\u00a0]+', ' ', 'g')), nfc);
  v_real := normalize(btrim(regexp_replace(v_emp.full_name, '[[:space:]\u00a0]+', ' ', 'g')), nfc);
  if v_typed = '' or v_typed <> v_real then
    raise exception 'name_mismatch' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.attendance_sessions s where s.employee_id = p_employee_id and s.status = 'open') then
    raise exception 'open_session' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.requests r where r.employee_id = p_employee_id and r.status = 'pending') then
    raise exception 'pending_requests' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.employees x where x.manager_id = p_employee_id and x.company_id = v_company and x.deleted_at is null) then
    raise exception 'has_reports' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.approval_steps a
             where a.company_id = v_company and a.approver_kind = 'specific_employee' and a.approver_employee_id = p_employee_id) then
    raise exception 'is_approver' using errcode = 'P0001';
  end if;

  update public.employees set deleted_at = now(), is_active = false where id = p_employee_id;
  perform public.admin_remove_device(p_employee_id);
  delete from public.push_subscriptions where user_id = p_employee_id and company_id = v_company;
  perform public.audit_write(v_company, 'employee.delete', 'employee', p_employee_id::text,
    jsonb_build_object('employee_number', v_emp.employee_number, 'full_name', v_emp.full_name));
  return jsonb_build_object('deleted', true);
end;
$$;
revoke all on function public.admin_delete_employee(uuid, text) from public, anon;
grant execute on function public.admin_delete_employee(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------------------- platform list
create or replace function public.platform_list_companies()
returns table(id uuid, name text, timezone text, is_active boolean, employees_count bigint, admins_count bigint, created_at timestamp with time zone)
language plpgsql
stable security definer
set search_path to 'public'
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
  select c.id, c.name, c.timezone, c.is_active,
         (select count(*) from public.employees e where e.company_id = c.id and e.deleted_at is null),
         (select count(*) from public.company_members m where m.company_id = c.id and m.role = 'company_admin'),
         c.created_at
  from public.companies c
  order by c.created_at;
end;
$$;
revoke all on function public.platform_list_companies() from public, anon;
grant execute on function public.platform_list_companies() to authenticated;
