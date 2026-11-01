-- Phase 8b: fingerprint check (spec docs/superpowers/specs/2026-11-01-biometric-punch-windows-design.md, section 2).
-- The Edge Function `webauthn` verifies a registration or a fingerprint signature and, through the service-role-only
-- functions below, stores the device or issues a single-use ticket for ONE punch (request_id), valid 2 minutes.
-- employee_punch consumes the ticket in the same transaction. A phone that cannot do it (and never registered) may
-- punch, flagged for review. Ships OFF (companies.biometric_policy = 'off', added in phase 8a).
-- Rollback: 20261102100000_phase8b_biometric_ROLLBACK.sql

do $guard$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'companies' and column_name = 'biometric_policy')
     or to_regprocedure('public.employee_punch(uuid, text, text, double precision, double precision, double precision)') is null then
    raise exception 'phase8b: run phase 8a first';
  end if;
end
$guard$;

create table public.webauthn_credentials (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  employee_id uuid not null unique references public.employees(id) on delete cascade,
  credential_id text not null unique check (length(credential_id) between 1 and 1024),
  public_key bytea not null,
  sign_count bigint not null default 0 check (sign_count >= 0),
  transports text[] not null default '{}',
  device_label text check (length(device_label) <= 120),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table public.webauthn_credentials enable row level security;
revoke all on table public.webauthn_credentials from public, anon, authenticated;

create table private.webauthn_challenges (
  employee_id uuid not null references public.employees(id) on delete cascade,
  purpose text not null check (purpose in ('register', 'punch')),
  challenge text not null,
  expires_at timestamptz not null,
  primary key (employee_id, purpose)
);
create table private.punch_tickets (
  employee_id uuid not null references public.employees(id) on delete cascade,
  request_id uuid not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  primary key (employee_id, request_id)
);
revoke all on table private.webauthn_challenges, private.punch_tickets from public, anon, authenticated;

create or replace function private.b64u_decode(p text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select decode(translate(p, '-_', '+/') || repeat('=', (4 - length(p) % 4) % 4), 'base64')
$$;
create or replace function private.b64u_encode(p bytea)
returns text
language sql
immutable
set search_path = ''
as $$
  select rtrim(translate(replace(encode(p, 'base64'), E'\n', ''), '+/', '-_'), '=')
$$;
revoke all on function private.b64u_decode(text), private.b64u_encode(bytea) from public, anon, authenticated;

-- ---------------------------------------------------------------- what the Edge Function reads with the CALLER's token
create or replace function public.employee_webauthn_context()
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  w public.webauthn_credentials;
begin
  select * into me from public.require_active_employee();
  select * into w from public.webauthn_credentials c where c.employee_id = me.employee_id;
  return jsonb_build_object(
    'employee_id', me.employee_id, 'company_id', me.company_id,
    'policy', (select c.biometric_policy from public.companies c where c.id = me.company_id),
    'has_device', w.id is not null,
    'user_name', coalesce(nullif(me.employee_number, ''), me.full_name),
    'display_name', me.full_name,
    'credential', case when w.id is null then null else jsonb_build_object(
      'credential_id', w.credential_id, 'public_key_b64u', private.b64u_encode(w.public_key),
      'sign_count', w.sign_count, 'transports', to_jsonb(w.transports)) end);
end;
$$;

-- ---------------------------------------------------------------- service role only (the Edge Function)
create or replace function public.service_webauthn_put_challenge(p_employee uuid, p_purpose text, p_challenge text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.webauthn_challenges (employee_id, purpose, challenge, expires_at)
  values (p_employee, p_purpose, p_challenge, now() + interval '2 minutes')
  on conflict (employee_id, purpose) do update set challenge = excluded.challenge, expires_at = excluded.expires_at;
end;
$$;

create or replace function public.service_webauthn_take_challenge(p_employee uuid, p_purpose text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v text;
begin
  delete from private.webauthn_challenges c where c.employee_id = p_employee and c.purpose = p_purpose
  returning case when c.expires_at > now() then c.challenge end into v;
  return v;
end;
$$;

create or replace function public.service_webauthn_register(p_employee uuid, p_credential_id text, p_public_key_b64u text,
  p_sign_count bigint, p_transports text[], p_label text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_company uuid;
begin
  select e.company_id into v_company from public.employees e where e.id = p_employee and e.is_active;
  if not found then raise exception 'employee_not_found' using errcode = '22023'; end if;
  if exists (select 1 from public.webauthn_credentials c where c.employee_id = p_employee) then
    raise exception 'device_already_registered' using errcode = 'P0001';
  end if;
  insert into public.webauthn_credentials (company_id, employee_id, credential_id, public_key, sign_count, transports, device_label)
  values (v_company, p_employee, p_credential_id, private.b64u_decode(p_public_key_b64u), coalesce(p_sign_count, 0),
          coalesce(p_transports, '{}'), left(nullif(btrim(p_label), ''), 120));
  insert into public.audit_log (company_id, actor_id, action, target_type, target_id, details)
  values (v_company, p_employee, 'device.register', 'employee', p_employee::text,
          jsonb_build_object('device_label', left(nullif(btrim(p_label), ''), 120)));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.service_webauthn_issue_ticket(p_employee uuid, p_credential_id text, p_new_count bigint, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare w public.webauthn_credentials;
begin
  select * into w from public.webauthn_credentials c
  where c.employee_id = p_employee and c.credential_id = p_credential_id for update;
  if not found or p_request_id is null then
    raise exception 'biometric_failed' using errcode = 'P0001';
  end if;
  -- A signature counter that does not grow means a copied key (when the device keeps a counter at all).
  if coalesce(p_new_count, 0) > 0 and w.sign_count > 0 and p_new_count <= w.sign_count then
    raise exception 'biometric_failed' using errcode = 'P0001';
  end if;
  update public.webauthn_credentials set sign_count = greatest(w.sign_count, coalesce(p_new_count, 0)), last_used_at = now()
  where id = w.id;
  insert into private.punch_tickets (employee_id, request_id, expires_at)
  values (p_employee, p_request_id, now() + interval '2 minutes')
  on conflict (employee_id, request_id) do update set expires_at = excluded.expires_at, used_at = null;
  return jsonb_build_object('ok', true);
end;
$$;

do $grants$
declare f text;
begin
  foreach f in array array[
    'public.service_webauthn_put_challenge(uuid, text, text)',
    'public.service_webauthn_take_challenge(uuid, text)',
    'public.service_webauthn_register(uuid, text, text, bigint, text[], text)',
    'public.service_webauthn_issue_ticket(uuid, text, bigint, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  execute 'revoke all on function public.employee_webauthn_context() from public, anon';
  execute 'grant execute on function public.employee_webauthn_context() to authenticated';
end
$grants$;

-- ---------------------------------------------------------------- the punch
drop function public.employee_punch(uuid, text, text, double precision, double precision, double precision);
create function public.employee_punch(p_request_id uuid, p_expected_action text, p_reading text,
  p_lat double precision default null, p_lng double precision default null, p_accuracy_m double precision default null,
  p_biometric text default 'ticket')
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_now timestamptz := now();
  v_result jsonb;
  v_meta jsonb := jsonb_build_object('source', 'pwa');
  v_saved jsonb;
begin
  select * into me from public.require_active_employee();
  if p_biometric is null or p_biometric not in ('ticket', 'unsupported') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  if (select c.biometric_policy from public.companies c where c.id = me.company_id) = 'required' then
    -- a retry of a punch that was already saved returns it (its ticket was used the first time)
    v_saved := private.existing_punch(p_request_id, me.employee_id);
    if v_saved is not null then
      return v_saved || jsonb_build_object('time_token', private.issue_time_token(me.employee_id, v_now));
    end if;
    if exists (select 1 from public.webauthn_credentials w where w.employee_id = me.employee_id) then
      if p_biometric <> 'ticket' then
        raise exception 'biometric_required' using errcode = 'P0001';
      end if;
      update private.punch_tickets t set used_at = v_now
       where t.employee_id = me.employee_id and t.request_id = p_request_id and t.used_at is null and t.expires_at > v_now;
      if not found then
        raise exception 'biometric_required' using errcode = 'P0001';
      end if;
      v_meta := v_meta || jsonb_build_object('auth_method', 'biometric');
    elsif p_biometric = 'unsupported' then
      v_meta := v_meta || jsonb_build_object('biometric', 'unsupported', 'review', true);
    else
      raise exception 'device_not_registered' using errcode = 'P0001';
    end if;
  end if;

  v_result := private.record_punch(
    me.employee_id, me.location_policy, me.outside_action, me.max_accuracy_m, me.timezone,
    p_request_id, p_expected_action, p_reading, p_lat, p_lng, p_accuracy_m, v_now, v_meta);
  return v_result || jsonb_build_object('time_token', private.issue_time_token(me.employee_id, v_now));
end;
$$;
revoke all on function public.employee_punch(uuid, text, text, double precision, double precision, double precision, text) from public, anon;
grant execute on function public.employee_punch(uuid, text, text, double precision, double precision, double precision, text) to authenticated, service_role;

-- ---------------------------------------------------------------- app state (+ biometric)
create or replace function public.employee_attendance_state()
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
  v_open public.attendance_sessions;
  v_started timestamptz;
  v_now timestamptz := now();
  v_win record;
begin
  select * into me from public.require_active_employee();
  perform private.close_missed_checkout(me.employee_id, v_now);

  select * into v_open from public.attendance_sessions s
  where s.employee_id = me.employee_id and s.status = 'open'
  order by s.created_at desc limit 1;
  if found then
    select ev.occurred_at into v_started from public.attendance_events ev where ev.id = v_open.check_in_event_id;
  end if;
  select * into v_win from private.punch_window(me.employee_id, case when v_open.id is null then 'check_in' else 'check_out' end, v_now);

  return jsonb_build_object(
    'employee', jsonb_build_object('full_name', me.full_name, 'employee_number', me.employee_number),
    'company', jsonb_build_object('name', me.company_name, 'timezone', me.timezone),
    'next_action', case when v_open.id is null then 'check_in' else 'check_out' end,
    'open_session', case when v_open.id is null then null else jsonb_build_object('started_at', v_started) end,
    'location_policy', me.location_policy,
    'outside_action', me.outside_action,
    'max_accuracy_m', me.max_accuracy_m,
    'biometric', jsonb_build_object('policy', (select c.biometric_policy from public.companies c where c.id = me.company_id),
                                    'has_device', exists (select 1 from public.webauthn_credentials w where w.employee_id = me.employee_id)),
    'punch_window', jsonb_build_object('allowed', v_win.allowed, 'opens_at', v_win.opens_at,
                                       'closes_at', v_win.closes_at, 'reason', v_win.reason),
    'recent_events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ev.id, 'action', ev.event_type, 'server_time', ev.occurred_at,
               'location_status', public.event_location_status(ev), 'needs_review', ev.needs_review)
             order by ev.occurred_at desc)
      from (select * from public.attendance_events x
            where x.employee_id = me.employee_id
            order by x.occurred_at desc limit 10) ev
    ), '[]'::jsonb),
    'server_time', v_now,
    'time_token', private.issue_time_token(me.employee_id, v_now)
  );
end;
$$;
revoke all on function public.employee_attendance_state() from public, anon;
grant execute on function public.employee_attendance_state() to authenticated;

-- ---------------------------------------------------------------- admin
create or replace function public.admin_remove_device(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_label text;
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
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_remove_device(uuid) from public, anon;
grant execute on function public.admin_remove_device(uuid) to authenticated;

create or replace function public.admin_get_employee_profile(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'employee_not_found' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'employee', (
      select to_jsonb(x) from (
        select e.id, e.employee_number, e.full_name, e.department, e.job_title, e.gender,
               e.birth_date, e.hire_date, e.work_location_id, e.is_active, e.geofence_required,
               e.location_policy, e.outside_action
        from public.employees e where e.id = p_employee_id and e.company_id = v_company
      ) x
    ),
    'base_salary', (select c.base_salary from public.employee_compensation c
                    where c.employee_id = p_employee_id and c.company_id = v_company),
    'components', coalesce((
      select jsonb_agg(jsonb_build_object('name', s.name, 'amount', s.amount) order by s.sort_order, s.id)
      from public.employee_salary_components s where s.employee_id = p_employee_id and s.company_id = v_company
    ), '[]'::jsonb),
    'schedule', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', w.weekday, 'is_workday', w.is_workday,
        'start_time', to_char(w.start_time, 'HH24:MI'), 'end_time', to_char(w.end_time, 'HH24:MI')
      ) order by w.weekday)
      from public.employee_work_schedules w where w.employee_id = p_employee_id and w.company_id = v_company
    ), '[]'::jsonb),
    'leave', coalesce((
      select jsonb_object_agg(l.leave_type, l.days)
      from public.employee_leave_entitlements l where l.employee_id = p_employee_id and l.company_id = v_company
    ), '{}'::jsonb),
    'punch_windows', (
      select jsonb_build_object('in_before_min', e.in_before_min, 'in_after_min', e.in_after_min,
                                'out_before_min', e.out_before_min, 'out_after_min', e.out_after_min)
      from public.employees e where e.id = p_employee_id),
    'device', (
      select jsonb_build_object('device_label', w.device_label, 'created_at', w.created_at, 'last_used_at', w.last_used_at)
      from public.webauthn_credentials w where w.employee_id = p_employee_id and w.company_id = v_company)
  );
end;
$$;

drop function public.admin_list_employees();
CREATE FUNCTION public.admin_list_employees()
 RETURNS TABLE(id uuid, email text, full_name text, employee_number text, department text, is_active boolean, geofence_required boolean, created_at timestamp with time zone, geofence_id uuid, geofence_name text, geofence_lat double precision, geofence_lng double precision, geofence_radius_meters numeric, job_title text, gender text, birth_date date, hire_date date, work_location_id uuid, work_location_name text, geofence_inherited boolean, location_policy text, outside_action text, has_device boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  where e.company_id = v_company
  order by e.created_at desc;
end;
$function$
;
revoke all on function public.admin_list_employees() from public, anon, authenticated, service_role;
grant execute on function public.admin_list_employees() to authenticated, service_role;

-- ---------------------------------------------------------------- admin attendance list: + biometric ('unsupported'), missed check-out
drop function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer);
create function public.admin_list_attendance(p_from timestamp with time zone default null, p_to timestamp with time zone default null,
  p_employee_id uuid default null, p_event_type public.attendance_event_type default null, p_limit integer default 50, p_offset integer default 0)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, email text, department text,
  event_type public.attendance_event_type, occurred_at timestamp with time zone, received_at timestamp with time zone,
  within_geofence boolean, geofence_enforced boolean, geofence_name text, distance_meters numeric, accuracy_meters numeric,
  latitude double precision, longitude double precision, authentication_method text, device_id text, total_count bigint,
  needs_review boolean, location_status text, source text, offline boolean, sync_delay_s integer, suspect text[],
  biometric text, missed_checkout boolean)
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select
    ev.id, ev.employee_id, emp.employee_number, emp.full_name, u.email::text, emp.department,
    ev.event_type, ev.occurred_at, ev.created_at, ev.within_geofence,
    coalesce((ev.metadata ->> 'geofence_enforced')::boolean, true),
    gf.name, ev.distance_from_geofence_meters, ev.accuracy_meters,
    extensions.st_y(ev.location::extensions.geometry), extensions.st_x(ev.location::extensions.geometry),
    ev.authentication_method, ev.device_id,
    count(*) over (),
    coalesce(ev.needs_review, false),
    ev.location_status,
    ev.metadata ->> 'source',
    coalesce((ev.metadata ->> 'offline')::boolean, false),
    (ev.metadata ->> 'sync_delay_s')::integer,
    coalesce(array(select jsonb_array_elements_text(ev.metadata -> 'suspect')), '{}'::text[]),
    ev.metadata ->> 'biometric',
    coalesce((ev.metadata ->> 'missed_checkout')::boolean, false)
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  join auth.users u on u.id = ev.employee_id
  left join public.employee_geofences gf on gf.id = ev.geofence_id
  where ev.company_id = v_company
    and (p_from is null or ev.occurred_at >= p_from)
    and (p_to is null or ev.occurred_at < p_to)
    and (p_employee_id is null or ev.employee_id = p_employee_id)
    and (p_event_type is null or ev.event_type = p_event_type)
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 50), 1000), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;
revoke all on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) from public, anon;
grant execute on function public.admin_list_attendance(timestamp with time zone, timestamp with time zone, uuid, public.attendance_event_type, integer, integer) to authenticated;
