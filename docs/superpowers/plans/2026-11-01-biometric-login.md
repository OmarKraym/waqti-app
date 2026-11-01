# Fingerprint login Implementation Plan

> Executed inline (executing-plans). Spec: docs/superpowers/specs/2026-11-01-biometric-login-design.md

**Goal:** employee signs in with the registered phone's fingerprint after signing out.
**Stack:** Postgres SECURITY DEFINER RPCs, Deno Edge Function `webauthn`, React app, Playwright (virtual authenticator).

## Review Focus
- signature from another credential or forged -> refused; challenge reused / expired / for another credential -> refused
- device removed by admin, employee inactive, temporary password, company policy off -> refused, no session
- 5 failures lock the credential; success resets; counter that does not grow -> refused
- sign-out then sign-in keeps notification settings; a second phone cannot punch

### Task 1: DB layer
Files: `supabase/migrations/20261102110000_phase9_biometric_login.sql` (+ `_ROLLBACK.sql`), `supabase/tests/phase9_biometric_login_tests.sql`.
Produces: `service_login_context(text)`, `service_login_put_challenge(text,text)->uuid`, `service_login_take_challenge(uuid,text)->text`,
`service_login_result(text,boolean,bigint)->jsonb`. Tests first (RED), then SQL. Run `supabase/local/test-db.sh`.

### Task 2: Edge Function
Files: `supabase/functions/webauthn/index.ts`, `index.test.mjs`. Add `login-options` / `login-verify` before the auth part.
Negative tests listed in Review Focus. Run `supabase/functions/webauthn/test.sh`.

### Task 3: App
Files: `src/lib/bioDevice.ts` (+test), `src/lib/biometric.ts`, `api.ts`, `supabaseApi.ts`, `mockApi.ts`, `screens/Login.tsx`, `styles.css`.
Browser check `bio_login_check.py` (virtual authenticator, mock + real build) and a notif sign-out check.

### Task 4: Review and verify
Fresh reviewer agent on the whole branch, one fix pass, all suites, report. No deploy before «انشر».
