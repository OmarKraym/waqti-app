# Fingerprint login (phase 9) - design

Approved by Omar 2026-11-01 («اوافق، ابدأ التنفيذ»), option "fingerprint instead of password" after sign-out.
Omar asked for three things: (1) one phone and no punching from another phone, (2) notification settings kept after
sign-out, (3) sign in with the fingerprint.

## Facts found before designing
- (1) already holds: `webauthn_credentials.employee_id` is unique, `employee_punch` needs a single-use ticket from the
  registered credential, only admin can remove the device. Phase 9 only adds a test that a second phone is refused.
- A friend's fingerprint enrolled in the phone's own settings (or the screen PIN) passes WebAuthn. No web app can stop that.
  With fingerprint login the same hole also opens the account, not just punches. Said to Omar; accepted.
- (2) `notification_settings` and `push_subscriptions` live on the server per employee; `signOut` is local only. Phase 9 pins
  this with a sign-out / sign-in test, no code change expected.

## Design
- Phone keeps `waqti-bio-device` in localStorage: `{credential_id}` (not a secret). Written after register-verify and after
  every punch-options. Survives sign-out. Cleared when the server says the device is gone.
- Login screen shows "ادخل بالبصمة" when the hint exists and the phone supports WebAuthn. Password form stays.
- Edge Function `webauthn` gets two actions that run BEFORE the authenticated part: `login-options`, `login-verify`.
  - login-options {credential_id}: unknown or ineligible -> `device_not_registered`; locked -> `too_many_attempts`;
    else new challenge (2 min, single use, max 3 active per credential) + `challenge_id`.
  - login-verify {credential_id, challenge_id, response}: takes the challenge (deleted), verifies signature
    (userVerification required, origin, RP ID), counter check, then checks employee active, no temporary password, company
    policy `required`. Success -> `auth.admin.generateLink({type:'magiclink', email})` -> returns `token_hash`; the app calls
    `verifyOtp({token_hash, type:'magiclink'})` and gets a normal session. Service key never leaves the function.
  - 5 failures per credential in 15 minutes -> locked for the rest of the window.
  - audit_log: `auth.biometric_login` (success), `auth.biometric_login_locked`.
- Database (`20261102110000_phase9_biometric_login.sql`): `private.login_challenges`, `private.login_failures`, service-only
  RPCs `service_login_context`, `service_login_put_challenge`, `service_login_take_challenge`, `service_login_result`.
  No new table readable by users.

## Not in scope
Native app, app lock on open, changing the RP ID, removing the password.

## Risks (told to Omar)
First unauthenticated path that mints sessions; shared RP ID `omarkraym.github.io`; iOS standalone PWA untested; the
`generateLink` + `verifyOtp` path can only be proven against the live Auth service after deploy.
