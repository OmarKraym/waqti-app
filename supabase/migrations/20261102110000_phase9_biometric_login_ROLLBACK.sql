-- Rollback of 20261102110000_phase9_biometric_login.sql: removes the login functions and tables.
-- Devices (webauthn_credentials) and punch tickets are not touched. Audit rows already written stay.
drop function if exists public.service_login_result(text, boolean, bigint);
drop function if exists public.service_login_take_challenge(uuid, text);
drop function if exists public.service_login_put_challenge(text, text);
drop function if exists public.service_login_context(text);
drop function if exists private.login_locked(text);
drop table if exists private.login_failures;
drop table if exists private.login_challenges;
