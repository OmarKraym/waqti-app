-- Phase 16d: an account opens only on the first phone it was used on (decided by Omar, 2026-11-04).
--   The app keeps a random key on the phone; the server keeps its hash (employee_devices). Every session (JWT session_id)
--   must be bound to that phone before any employee function works (public.require_active_employee checks it).
--   Another phone gets "device_locked" ("لا يمكنك الدخول من هاتف آخر"), even with the right password.
--   The admin unbinds with the existing admin_remove_device (one step, the password does not change). After that the
--   first phone that SIGNS IN AGAIN is bound; an old session cannot take the account back (login_again).
--   companies.device_lock = false switches the rule off for a company (emergency switch, no screen).
--   Tokens without a session_id (not issued by Supabase Auth for users) are not affected.
-- Rollback: 20261104190000_phase16d_device_lock_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('public.require_active_employee()') is null
     or to_regprocedure('public.admin_remove_device(uuid)') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regclass('auth.sessions') is null then
    raise exception 'phase16d: expected objects are missing';
  end if;
end
$guard$;

alter table public.companies add column if not exists device_lock boolean not null default true;
-- Existing companies start with the lock OFF: phones still running the previous app version do not bind. It is
-- switched on (update companies set device_lock = true) once the phones run the new version. New companies: on.
update public.companies set device_lock = false;

create table if not exists public.employee_devices (
  employee_id uuid primary key references public.employees (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  key_hash text not null,
  user_agent text,
  bound_at timestamptz not null default now()
);
alter table public.employee_devices enable row level security;
revoke all on public.employee_devices from public, anon, authenticated;

create table if not exists private.device_sessions (
  session_id uuid primary key,
  employee_id uuid not null references public.employees (id) on delete cascade,
  bound_at timestamptz not null default now()
);
create index if not exists device_sessions_employee_idx on private.device_sessions (employee_id);

create table if not exists private.device_unbinds (
  employee_id uuid primary key references public.employees (id) on delete cascade,
  unbound_at timestamptz not null
);

-- ---------------------------------------------------------------- the check behind every employee function
create or replace function public.require_active_employee()
returns table (employee_id uuid, company_id uuid, location_policy text, outside_action text, max_accuracy_m numeric,
               timezone text, full_name text, employee_number text, company_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_sid uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_lock boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) then
    raise exception 'must_change_password' using errcode = '42501';
  end if;
  select c.device_lock into v_lock
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = v_uid and e.is_active and c.is_active;
  if not found then
    raise exception 'employee_inactive' using errcode = '42501';
  end if;
  if v_lock and v_sid is not null
     and not exists (select 1 from private.device_sessions d where d.session_id = v_sid and d.employee_id = v_uid) then
    raise exception 'device_not_bound' using errcode = '42501';
  end if;
  return query
  select e.id, e.company_id, e.location_policy, coalesce(e.outside_action, c.default_outside_action),
         c.max_accuracy_m, c.timezone, e.full_name, e.employee_number, c.name
  from public.employees e
  join public.companies c on c.id = e.company_id
  where e.id = v_uid and e.is_active and c.is_active;
end;
$$;
revoke all on function public.require_active_employee() from public, anon, authenticated;
grant execute on function public.require_active_employee() to service_role;

-- ---------------------------------------------------------------- bind this session to this phone
create or replace function public.employee_bind_device(p_key text, p_user_agent text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_sid uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_company uuid;
  v_lock boolean;
  v_hash text;
  v_have text;
  v_unbound timestamptz;
  v_started timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'must_change_password')::boolean, false) then
    raise exception 'must_change_password' using errcode = '42501';
  end if;
  select e.company_id, c.device_lock into v_company, v_lock
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = v_uid and e.is_active and c.is_active;
  if not found then
    raise exception 'employee_inactive' using errcode = '42501';
  end if;
  if p_key is null or p_key !~ '^[A-Za-z0-9_-]{43,128}$' or v_sid is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if not v_lock then
    -- Lock switched off: nothing is recorded, so switching it on again binds from scratch.
    return jsonb_build_object('ok', true, 'lock', false);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('waqti.device:' || v_uid::text, 0));
  v_hash := encode(extensions.digest(p_key, 'sha256'), 'hex');
  select d.key_hash into v_have from public.employee_devices d where d.employee_id = v_uid;
  if found then
    if v_have is distinct from v_hash then
      raise exception 'device_locked' using errcode = '42501';
    end if;
  else
    -- After an unbind, only a session started AFTER it may bind (the old phone cannot take the account back).
    select u.unbound_at into v_unbound from private.device_unbinds u where u.employee_id = v_uid;
    if v_unbound is not null then
      select s.created_at into v_started from auth.sessions s where s.id = v_sid;
      if v_started is null or v_started <= v_unbound then
        raise exception 'login_again' using errcode = '42501';
      end if;
    end if;
    insert into public.employee_devices (employee_id, company_id, key_hash, user_agent)
    values (v_uid, v_company, v_hash, left(p_user_agent, 300));
    perform public.audit_write(v_company, 'device.bound', 'employee', v_uid::text, jsonb_build_object('user_agent', left(p_user_agent, 300)));
  end if;
  insert into private.device_sessions (session_id, employee_id) values (v_sid, v_uid)
  on conflict (session_id) do nothing;
  if not exists (select 1 from private.device_sessions d where d.session_id = v_sid and d.employee_id = v_uid) then
    raise exception 'invalid_input' using errcode = '22023'; -- a session id that belongs to someone else
  end if;
  return jsonb_build_object('ok', true, 'lock', true);
end;
$$;
revoke all on function public.employee_bind_device(text, text) from public, anon;
grant execute on function public.employee_bind_device(text, text) to authenticated;

-- ---------------------------------------------------------------- the admin unbinds (fingerprint and phone, one step)
create or replace function public.admin_remove_device(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_label text;
  v_bound boolean;
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;
  delete from public.webauthn_credentials where employee_id = p_employee_id and company_id = v_company
  returning device_label into v_label;
  delete from private.punch_tickets where employee_id = p_employee_id;
  if found or v_label is not null then
    perform public.audit_write(v_company, 'device.remove', 'employee', p_employee_id::text, jsonb_build_object('device_label', v_label));
  end if;
  delete from public.employee_devices where employee_id = p_employee_id;
  v_bound := found;
  delete from private.device_sessions where employee_id = p_employee_id;
  insert into private.device_unbinds (employee_id, unbound_at) values (p_employee_id, clock_timestamp())
  on conflict (employee_id) do update set unbound_at = excluded.unbound_at;
  if v_bound then
    perform public.audit_write(v_company, 'device.unbound', 'employee', p_employee_id::text, '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_remove_device(uuid) from public, anon;
grant execute on function public.admin_remove_device(uuid) to authenticated;

create or replace function public.admin_list_device_bindings()
returns table (employee_id uuid, bound_at timestamptz, user_agent text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query select d.employee_id, d.bound_at, d.user_agent from public.employee_devices d where d.company_id = v_company;
end;
$$;
revoke all on function public.admin_list_device_bindings() from public, anon;
grant execute on function public.admin_list_device_bindings() to authenticated;
