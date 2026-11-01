-- Phase 9: sign in with the registered phone's fingerprint (spec docs/superpowers/specs/2026-11-01-biometric-login-design.md).
-- The Edge Function `webauthn` (actions login-options / login-verify) is the only caller, with the service role.
-- It never trusts the app: the employee, e-mail and key all come from here, by credential id.
--   * a challenge is single use, bound to the credential, 2 minutes, at most 3 alive per credential
--   * 5 failed attempts per credential in 15 minutes lock it (no challenge, no verification) until the window passes
--   * every successful sign-in and every lock is written to audit_log
-- Rollback: 20261102110000_phase9_biometric_login_ROLLBACK.sql

do $guard$
begin
  if to_regclass('public.webauthn_credentials') is null then
    raise exception 'phase9: run phase 8b first';
  end if;
end
$guard$;

create table private.login_challenges (
  challenge_id uuid primary key default gen_random_uuid(),
  credential_id text not null,
  challenge text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index login_challenges_credential_idx on private.login_challenges (credential_id, created_at);

create table private.login_failures (
  credential_id text not null,
  at timestamptz not null default now()
);
create index login_failures_credential_idx on private.login_failures (credential_id, at);

revoke all on table private.login_challenges, private.login_failures from public, anon, authenticated;

-- True when the credential has used up its failures for the current 15 minutes.
create or replace function private.login_locked(p_credential_id text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select count(*) >= 5 from private.login_failures f
  where f.credential_id = p_credential_id and f.at > now() - interval '15 minutes'
$$;
revoke all on function private.login_locked(text) from public, anon, authenticated;

-- Who may sign in with this credential. Raises: device_not_registered (no such device, or the employee / company is
-- inactive: nothing more is said), too_many_attempts, password_required (temporary password), biometric_off.
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
begin
  select * into w from public.webauthn_credentials c where c.credential_id = p_credential_id;
  if not found then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  select u.email::text, coalesce((u.raw_app_meta_data ->> 'must_change_password')::boolean, false), c.biometric_policy
    into v_email, v_must, v_policy
  from public.employees e
  join public.companies c on c.id = e.company_id
  join auth.users u on u.id = e.id
  where e.id = w.employee_id and e.is_active and c.is_active;
  if not found or v_email is null then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  if private.login_locked(p_credential_id) then
    raise exception 'too_many_attempts' using errcode = 'P0001';
  end if;
  if v_must then
    raise exception 'password_required' using errcode = 'P0001';
  end if;
  if v_policy is distinct from 'required' then
    raise exception 'biometric_off' using errcode = 'P0001';
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
declare v_id uuid;
begin
  if not exists (select 1 from public.webauthn_credentials c where c.credential_id = p_credential_id) then
    raise exception 'device_not_registered' using errcode = 'P0001';
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

-- Returns the challenge once (it is deleted), only for the credential it was made for, only while alive.
create or replace function public.service_login_take_challenge(p_challenge_id uuid, p_credential_id text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v text;
begin
  delete from private.login_challenges c
  where c.challenge_id = p_challenge_id and c.credential_id = p_credential_id
  returning case when c.expires_at > now() then c.challenge end into v;
  return v;
end;
$$;

-- Records the outcome of one verification. Returns {ok, error?}; a refusal is a RETURN (not a raise) so that the
-- failure it records is kept. Raises only for: device_not_registered, too_many_attempts.
create or replace function public.service_login_result(p_credential_id text, p_ok boolean, p_new_count bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.webauthn_credentials;
  v_fails int;
begin
  select * into w from public.webauthn_credentials c where c.credential_id = p_credential_id for update;
  if not found then
    raise exception 'device_not_registered' using errcode = 'P0001';
  end if;
  if private.login_locked(p_credential_id) then
    raise exception 'too_many_attempts' using errcode = 'P0001';
  end if;
  -- A signature counter that does not grow means a copied key (when the device keeps a counter at all).
  if p_ok and coalesce(p_new_count, 0) > 0 and w.sign_count > 0 and p_new_count <= w.sign_count then
    p_ok := false;
  end if;
  if not p_ok then
    delete from private.login_failures where at < now() - interval '1 day';
    insert into private.login_failures (credential_id) values (p_credential_id);
    select count(*) into v_fails from private.login_failures f
    where f.credential_id = p_credential_id and f.at > now() - interval '15 minutes';
    if v_fails = 5 then
      insert into public.audit_log (company_id, actor_id, action, target_type, target_id, details)
      values (w.company_id, w.employee_id, 'auth.biometric_login_locked', 'employee', w.employee_id::text,
              jsonb_build_object('device_label', w.device_label));
    end if;
    return jsonb_build_object('ok', false, 'error', 'biometric_failed');
  end if;
  update public.webauthn_credentials set sign_count = greatest(w.sign_count, coalesce(p_new_count, 0)), last_used_at = now()
  where id = w.id;
  delete from private.login_failures where credential_id = p_credential_id;
  insert into public.audit_log (company_id, actor_id, action, target_type, target_id, details)
  values (w.company_id, w.employee_id, 'auth.biometric_login', 'employee', w.employee_id::text,
          jsonb_build_object('device_label', w.device_label));
  return jsonb_build_object('ok', true);
end;
$$;

do $grants$
declare f text;
begin
  foreach f in array array[
    'public.service_login_context(text)',
    'public.service_login_put_challenge(text, text)',
    'public.service_login_take_challenge(uuid, text)',
    'public.service_login_result(text, boolean, bigint)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end
$grants$;
