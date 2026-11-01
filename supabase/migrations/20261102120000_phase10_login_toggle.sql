-- Phase 10: the employee can turn fingerprint SIGN-IN on or off from the profile screen.
--   * webauthn_credentials.login_enabled (default true: phones registered before this phase keep working)
--   * off = the sign-in functions refuse (login_disabled), enforced HERE, not in the app. The device stays registered, so the
--     punch fingerprint (a company rule) is not affected.
--   * turning it ON needs a fresh fingerprint: the Edge Function verifies the signature, then calls service_webauthn_set_login
--     with the new signature counter (a counter that does not grow = copied key = refused). Turning it OFF needs nothing.
--   * both changes are written to audit_log (once per real change)
-- Rollback: 20261102120000_phase10_login_toggle_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('public.service_login_context(text)') is null then
    raise exception 'phase10: run phase 9 first';
  end if;
end
$guard$;

alter table public.webauthn_credentials add column login_enabled boolean not null default true;

create or replace function public.service_login_context(p_credential_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.webauthn_credentials;
  v_email text;
  v_must boolean;
  v_policy text;
  v_active boolean;
begin
  select * into w from public.webauthn_credentials c where c.credential_id = p_credential_id;
  if not found then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  select u.email::text, coalesce((u.raw_app_meta_data ->> 'must_change_password')::boolean, false), c.biometric_policy,
         (e.is_active and c.is_active)
    into v_email, v_must, v_policy, v_active
  from public.employees e
  join public.companies c on c.id = e.company_id
  join auth.users u on u.id = e.id
  where e.id = w.employee_id;
  if not found or v_email is null then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  if not v_active then
    raise exception 'employee_inactive' using errcode = 'P0001';
  end if;
  if private.login_locked(p_credential_id) then
    raise exception 'too_many_attempts' using errcode = 'P0001';
  end if;
  if v_must
     or exists (select 1 from public.company_members m where m.user_id = w.employee_id and m.role = 'company_admin')
     or exists (select 1 from public.platform_admins pa where pa.user_id = w.employee_id) then
    raise exception 'password_required' using errcode = 'P0001';
  end if;
  if v_policy is distinct from 'required' then
    raise exception 'biometric_off' using errcode = 'P0001';
  end if;
  if not w.login_enabled then
    raise exception 'login_disabled' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'employee_id', w.employee_id, 'company_id', w.company_id, 'email', v_email,
    'credential', jsonb_build_object('credential_id', w.credential_id, 'public_key_b64u', private.b64u_encode(w.public_key),
                                     'sign_count', w.sign_count, 'transports', to_jsonb(w.transports)));
end;
$$;

create or replace function public.service_login_put_challenge(p_credential_id text, p_challenge text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  w public.webauthn_credentials;
begin
  select * into w from public.webauthn_credentials c where c.credential_id = p_credential_id;
  if not found then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  if not w.login_enabled then
    raise exception 'login_disabled' using errcode = 'P0001';
  end if;
  if private.login_locked(p_credential_id) then
    raise exception 'too_many_attempts' using errcode = 'P0001';
  end if;
  delete from private.login_challenges where expires_at < now();
  insert into private.login_challenges (credential_id, challenge, expires_at)
  values (p_credential_id, p_challenge, now() + interval '2 minutes')
  returning challenge_id into v_id;
  -- keep the 3 newest for this credential
  delete from private.login_challenges d
  where d.credential_id = p_credential_id
    and d.challenge_id not in (select x.challenge_id from private.login_challenges x
                               where x.credential_id = p_credential_id order by x.created_at desc, x.challenge_id limit 3);
  return v_id;
end;
$$;

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
    'login_enabled', coalesce(w.login_enabled, false),
    'user_name', coalesce(nullif(me.employee_number, ''), me.full_name),
    'display_name', me.full_name,
    'credential', case when w.id is null then null else jsonb_build_object(
      'credential_id', w.credential_id, 'public_key_b64u', private.b64u_encode(w.public_key),
      'sign_count', w.sign_count, 'transports', to_jsonb(w.transports)) end);
end;
$$;

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
                                    'has_device', exists (select 1 from public.webauthn_credentials w where w.employee_id = me.employee_id),
                                    'login_enabled', coalesce((select w.login_enabled from public.webauthn_credentials w where w.employee_id = me.employee_id), false)),
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

-- Service role only (the Edge Function). Returns {login_enabled}. Raises: device_not_registered, biometric_failed.
create or replace function public.service_webauthn_set_login(p_employee uuid, p_enabled boolean, p_new_count bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.webauthn_credentials;
begin
  select * into w from public.webauthn_credentials c where c.employee_id = p_employee for update;
  if not found then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  -- A signature counter that does not grow means a copied key (when the device keeps a counter at all).
  if p_enabled and coalesce(p_new_count, 0) > 0 and w.sign_count > 0 and p_new_count <= w.sign_count then
    raise exception 'biometric_failed' using errcode = 'P0001';
  end if;
  update public.webauthn_credentials
     set login_enabled = p_enabled,
         sign_count = greatest(w.sign_count, coalesce(p_new_count, 0)),
         last_used_at = case when p_new_count is null then w.last_used_at else now() end
   where id = w.id;
  if w.login_enabled is distinct from p_enabled then
    insert into public.audit_log (company_id, actor_id, action, target_type, target_id, details)
    values (w.company_id, w.employee_id,
            case when p_enabled then 'auth.biometric_login_enabled' else 'auth.biometric_login_disabled' end,
            'employee', w.employee_id::text, jsonb_build_object('device_label', w.device_label));
  end if;
  return jsonb_build_object('login_enabled', p_enabled);
end;
$$;

do $grants$
begin
  execute 'revoke all on function public.service_webauthn_set_login(uuid, boolean, bigint) from public, anon, authenticated';
  execute 'grant execute on function public.service_webauthn_set_login(uuid, boolean, bigint) to service_role';
end
$grants$;
