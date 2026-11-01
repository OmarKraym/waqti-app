# Fingerprint Check and Punch Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A company can require a server-verified fingerprint (WebAuthn) for every punch, and can limit punching to windows around each employee's shift, with overtime opening its own window.

**Architecture:** All rules live in Postgres: `private.punch_window()` decides when a punch is allowed, `private.record_punch()` enforces it and closes missed check-outs, and `employee_punch()` consumes a single-use ticket. A new Edge Function `webauthn` verifies registrations and assertions with `@simplewebauthn/server` and writes credentials and tickets through service-role-only RPCs. The PWA disables the button outside the window and runs the fingerprint step before each punch; the admin panel gets the settings, per-employee overrides and device removal.

**Tech Stack:** Postgres 16 / Supabase (plpgsql, SECURITY DEFINER RPCs), Deno Edge Functions with `npm:@simplewebauthn/server@13.2.3`, React 19 PWA with `@simplewebauthn/browser@13.2.2`, plain-JS admin panel, Playwright checks.

**Spec:** `docs/superpowers/specs/2026-11-01-biometric-punch-windows-design.md` (approved 2026-11-01, assumptions 1–4 confirmed).

## Global Constraints

- Both features ship **off** for every company: `companies.biometric_policy default 'off'`, `companies.punch_windows_enabled default false`.
- RP ID `omarkraym.github.io`; expected origin `https://omarkraym.github.io`; `userVerification: 'required'`; `authenticatorAttachment: 'platform'`; challenges and tickets expire after **2 minutes**; one device per employee.
- Window defaults (minutes): `in_before_min 60`, `in_after_min 120`, `out_before_min 120`, `out_after_min 60`; allowed range **0–720**; employee values null = company value.
- Server time only (`now()`); never trust a time sent by the client. Company always from the caller's membership, never from the client.
- Every admin change audited (`device.register`, `device.remove`, `company.punch_settings`, `employee.punch_windows`).
- Error codes (exact): `biometric_required`, `device_not_registered`, `device_already_registered`, `biometric_failed`, `outside_punch_window`, `day_off`.
- Arabic UI strings (exact): «سجّل بصمتك لهذا الجهاز», «هذا الجهاز لا يدعم البصمة؛ ستُعلَّم بصماتك للمراجعة», «لم تتم البصمة», «البصم متاح من H:MM إلى H:MM», «اليوم عطلة», «انتهى وقت البصم لليوم», «بدون بصمة», «بدون خروج», «تقييد أوقات البصم», «البصمة: معطّلة / إلزامية», «الجهاز المسجّل», «إلغاء تسجيل الجهاز», «قيمة الشركة».
- No service-role key in any frontend; new tables have RLS on with no policies and no grants to anon/authenticated.
- The admin panel's visual design does not change: reuse `modal`, `field`, `checkbox`, `badge` classes.
- Each migration ships with a `_ROLLBACK.sql`; the DB test runner `supabase/local/test-db.sh` must stay green (currently 223).

## Review Focus

1. **Night shift across midnight** (`end_time <= start_time`): an employee checking out at 01:30 for a 22:00–06:00 shift must be allowed by yesterday's shift — test in Task 1.
2. **Employee with an open session from yesterday when windows are on**: the next morning's check-in must work (session closed as `missed_checkout`), not fail with `state_changed` — test in Task 1.
3. **Ticket replay / theft**: a ticket for request A used for request B, a used ticket, an expired ticket, another employee's ticket — all refused — tests in Task 2.
4. **Phone clock wrong**: the app must show the window from `server_time`, not the phone clock; the button state follows the server answer — test in Task 4 (state with `punch_window.allowed=false` disables the button whatever the phone time).
5. **Cancelled fingerprint prompt or a phone without WebAuthn** while the company requires it: nothing is recorded on cancel; unsupported phone records with review — tests in Task 2 (server) and Task 4 (UI).

---

### Task 1: Punch windows in the database

**Files:**
- Create: `supabase/migrations/20261102090000_phase8a_punch_windows.sql`, `..._ROLLBACK.sql`
- Test: `supabase/tests/phase8a_punch_windows_tests.sql`

**Interfaces:**
- Produces:
  - columns `companies.punch_windows_enabled boolean not null default false`, `companies.in_before_min, in_after_min, out_before_min, out_after_min smallint not null` (defaults 60/120/120/60, check 0–720); `employees.` same four `smallint null` (check 0–720).
  - enum value `attendance_session_status 'missed_checkout'`; constraint `attendance_sessions_status_check` becomes: open ⇒ no check-out event; closed ⇒ has one; missed_checkout ⇒ none.
  - `private.punch_window(p_employee uuid, p_action text, p_at timestamptz) returns table(allowed boolean, opens_at timestamptz, closes_at timestamptz, reason text)` — reason ∈ `no_limits, shift, overtime, day_off, too_early, too_late`. When not allowed, `opens_at/closes_at` give the next window today (or null).
  - `private.close_missed_checkout(p_employee uuid, p_at timestamptz) returns boolean` — closes an open session whose check-out window has ended and no overtime window is open; sets the check-in event `needs_review = true`, `metadata.missed_checkout = true`; audit not needed.
  - `private.record_punch(...)` (same signature): calls `close_missed_checkout` first, then `punch_window(p_employee_id, v_action, p_time)`; refuses with `outside_punch_window` (or `day_off`) using `detail` = `opens_at|closes_at` ISO; reads `p_meta->>'auth_method'` for `authentication_method` (default `'password'`).
  - `employee_attendance_state()` adds key `punch_window` `{allowed, opens_at, closes_at, reason}` for `next_action`, after calling `close_missed_checkout(me.employee_id, now())`.
  - `admin_get_punch_settings() returns jsonb` `{biometric_policy, punch_windows_enabled, in_before_min, in_after_min, out_before_min, out_after_min}` and `admin_set_punch_settings(p_biometric_policy text, p_windows_enabled boolean, p_in_before int, p_in_after int, p_out_before int, p_out_after int) returns jsonb` (audit `company.punch_settings`). `biometric_policy` column is created here too (`text not null default 'off' check in ('off','required')`) so settings are one RPC.
  - `admin_set_employee_punch_windows(p_employee_id uuid, p_in_before int, p_in_after int, p_out_before int, p_out_after int) returns jsonb` (nulls = company value; audit `employee.punch_windows`); `admin_get_employee_profile` adds key `punch_windows` `{in_before_min,…}` (nulls kept).
- Window rule (the one algorithm the signature does not fix): candidate windows = today's and yesterday's shift from `employee_work_schedules` (shift end = next day when `end_time <= start_time`) plus every `overtime_assignments` row with `status='assigned'` overlapping `p_at ± 1 day`. For `check_in`: `[start − in_before, start + in_after]`; for `check_out`: `[end − out_before, end + out_after]`. Allowed if `p_at` is inside any. No schedule rows at all, or feature off → `no_limits`. No workday today and no overtime → `day_off`. Otherwise `too_early` (a later window today exists) or `too_late`.

- [ ] **Step 1: Write the failing tests** (`phase8a_punch_windows_tests.sql`, same harness as `security_fixes_r1_tests.sql`). Fix the employee's schedule in the test (all 7 days 08:00–16:00 except one day off) and move "now" with explicit `p_at` values on `private.punch_window`; for `employee_punch` move earlier events back as the existing tests do. Assertions:
  - feature off → `allowed`, reason `no_limits`; feature on + employee without schedule rows → `no_limits`.
  - check-in at 07:00 allowed (edge `08:00−60`), 06:59 refused `too_early`, 10:00 allowed, 10:01 refused `too_late`.
  - check-out 14:00 allowed, 13:59 refused, 17:00 allowed, 17:01 refused.
  - employee override `in_before_min = 30` → 07:30 allowed, 07:29 refused; company value used for the other three.
  - day off → `day_off`; day off with an `assigned` overtime 18:00–20:00 → check-in 17:00 allowed (`overtime`); cancelled overtime → `day_off`.
  - night shift 22:00–06:00: check-out at 01:30 next day allowed; check-in 21:00 allowed.
  - `employee_punch` at a refused time raises `outside_punch_window`; nothing inserted.
  - open session whose check-out window ended → `employee_attendance_state()` shows `next_action = 'check_in'`, session status `missed_checkout`, its check-in event `needs_review`.
  - `admin_set_punch_settings` refuses 721 and −1 (`invalid_punch_settings`), refuses a non-admin (`forbidden`), audits; another company's employee in `admin_set_employee_punch_windows` → `employee_not_found`.
- [ ] **Step 2:** Run `cd supabase && PGHOST=/var/lib/waqti-test-pg PGPORT=54329 PGUSER=postgres ./local/test-db.sh` under a fixed clock (`pg_at.sh "2026-10-31 10:00:00"`). Expected: new file fails (functions missing), the 8 old files still pass.
- [ ] **Step 3:** Write the migrations. The enum value goes in its own file `20261102085900_phase8a_enum.sql` (`alter type public.attendance_session_status add value if not exists 'missed_checkout'`), because Postgres cannot use a new enum value in the transaction that adds it; the main file guards on the current `record_punch` signature. Add the enum file to the runner order (it sorts first by name).
- [ ] **Step 4:** Run the runner again. Expected: `TOTAL passed=… failed=0`.
- [ ] **Step 5:** Write `_ROLLBACK.sql` (restore previous `record_punch`, `employee_attendance_state`, `admin_get_employee_profile`; drop new functions and columns; the enum value cannot be dropped — leave it, constraint restored). Verify: apply migration + rollback on a fresh copy, function hashes identical to before (same check as R1).
- [ ] **Step 6:** Commit `feat(db): punch windows per employee with overtime and missed check-out`.

### Task 2: Fingerprint rules in the database

**Files:**
- Create: `supabase/migrations/20261102100000_phase8b_biometric.sql`, `..._ROLLBACK.sql`
- Test: `supabase/tests/phase8b_biometric_tests.sql`

**Interfaces:**
- Consumes: `companies.biometric_policy` (Task 1), `private.record_punch` reading `p_meta->>'auth_method'` (Task 1).
- Produces:
  - `public.webauthn_credentials(id uuid pk default gen_random_uuid(), company_id uuid not null, employee_id uuid not null unique references employees, credential_id text not null unique, public_key bytea not null, sign_count bigint not null default 0, transports text[] not null default '{}', device_label text check (length ≤ 120), created_at timestamptz default now(), last_used_at timestamptz)`; RLS on, no policies, all privileges revoked from anon/authenticated.
  - `private.webauthn_challenges(employee_id uuid, purpose text check in ('register','punch'), challenge text not null, expires_at timestamptz not null, primary key (employee_id, purpose))`.
  - `private.punch_tickets(employee_id uuid, request_id uuid, expires_at timestamptz not null, used_at timestamptz, primary key (employee_id, request_id))`.
  - `public.employee_webauthn_context() returns jsonb` (authenticated): `{employee_id, company_id, policy, has_device, credential: {credential_id, public_key_b64u, sign_count, transports} | null, user_name}` — uses `require_active_employee()`.
  - service_role-only: `service_webauthn_put_challenge(p_employee uuid, p_purpose text, p_challenge text)`, `service_webauthn_take_challenge(p_employee uuid, p_purpose text) returns text` (deletes the row; null if missing or expired), `service_webauthn_register(p_employee uuid, p_credential_id text, p_public_key_b64u text, p_sign_count bigint, p_transports text[], p_label text) returns jsonb` (raises `device_already_registered`; audit `device.register`), `service_webauthn_issue_ticket(p_employee uuid, p_credential_id text, p_new_count bigint, p_request_id uuid) returns jsonb` (credential must belong to the employee; when both counts > 0 the new count must be greater, else `biometric_failed`; updates `sign_count`, `last_used_at`; upserts ticket expiring now+2 min).
  - `public.employee_punch(p_request_id uuid, p_expected_action text, p_reading text, p_lat double precision default null, p_lng double precision default null, p_accuracy_m double precision default null, p_biometric text default 'ticket')` — replaces the 6-argument version (drop + create, grants to authenticated). Policy `required`: has device → consume unused, unexpired ticket `(employee, request_id)` in the same transaction, else `biometric_required`; `p_biometric='unsupported'` with a device → `biometric_required`; no device + `'unsupported'` → punch with `needs_review` and `metadata.biometric='unsupported'`; no device + `'ticket'` → `device_not_registered`. Passes `auth_method` `'biometric'` or `'password'` in `p_meta`. A retry of an already-saved `request_id` returns the saved punch before the ticket check (idempotency kept).
  - `admin_remove_device(p_employee_id uuid) returns jsonb` (audit `device.remove`); `admin_get_employee_profile` adds key `device` `{device_label, created_at, last_used_at} | null`; `admin_list_employees` adds `has_device boolean`.
  - `employee_attendance_state()` adds `biometric: {policy, has_device}`.

- [ ] **Step 1: Write the failing tests.** Assertions:
  - policy off: `employee_punch` without ticket works, `authentication_method='password'`.
  - policy required, no device: `'ticket'` → `device_not_registered`; `'unsupported'` → saved, `needs_review`, `metadata.biometric='unsupported'`.
  - after `service_webauthn_register` (as service_role): second register → `device_already_registered`; punch without ticket → `biometric_required`; `'unsupported'` → `biometric_required`.
  - ticket issued for request A: punch with request B → `biometric_required`; punch A → ok, `authentication_method='biometric'`; reuse A on a new punch → refused; expired ticket (update `expires_at` to past) → refused; ticket of employee X used by employee Y → refused.
  - `service_webauthn_issue_ticket` with a lower sign count → `biometric_failed`; with 0/0 → ok.
  - `service_webauthn_take_challenge` returns the value once, then null; expired → null.
  - grants: authenticated cannot execute any `service_webauthn_*`; anon/authenticated have no privilege on the three tables.
  - `admin_remove_device` other company → `employee_not_found`; own company → device gone, audit row; employee cannot call it.
  - old clients: `employee_punch` called with 6 named arguments still works when policy is off.
- [ ] **Step 2:** Run the runner; expect the new file to fail.
- [ ] **Step 3:** Write the migration.
- [ ] **Step 4:** Run the runner; expect all files to pass.
- [ ] **Step 5:** Rollback file + hash round-trip check as in Task 1.
- [ ] **Step 6:** Commit `feat(db): server-checked fingerprint tickets for punches`.

### Task 3: Edge Function `webauthn`

**Files:**
- Create: `supabase/functions/webauthn/index.ts` (HTTP, auth, DB calls), `supabase/functions/webauthn/core.ts` (pure: options + verification wrappers, no network)
- Test: `supabase/functions/webauthn/core.test.mjs` (Node 22, run from the scratch harness with `@simplewebauthn/server@13.2.3` and a software authenticator built with `node:crypto` + `cbor-x`)

**Interfaces:**
- Consumes: RPCs from Task 2.
- Produces: `POST /functions/v1/webauthn` (verify_jwt on), body `{action, ...}`:
  - `{action:'register-options'}` → `PublicKeyCredentialCreationOptionsJSON`
  - `{action:'register-verify', response: RegistrationResponseJSON, label?: string}` → `{ok:true}`
  - `{action:'punch-options'}` → `PublicKeyCredentialRequestOptionsJSON`
  - `{action:'punch-verify', response: AuthenticationResponseJSON, request_id: uuid}` → `{ok:true}`
  - errors `{error: code}` with codes from Global Constraints plus `not_authenticated` (401), `forbidden` (403), `invalid_input` (400).
- `core.ts` exports: `RP = { id: 'omarkraym.github.io', name: 'وقتي', origin: 'https://omarkraym.github.io' }`; `registrationOptions(userId: string, userName: string)`, `verifyRegistration(response, expectedChallenge)`, `authenticationOptions(credentialId: string, transports: string[])`, `verifyAuthentication(response, expectedChallenge, credential: {id, publicKey: Uint8Array, counter, transports})` — thin wrappers that pin the RP values and `requireUserVerification: true`.
- `index.ts` flow: caller from `userClient.auth.getUser()`; context from `userClient.rpc('employee_webauthn_context')` (so inactive/temporary-password users are refused by the DB); policy must be `required` for register; everything written through the service-role RPCs. Never logs challenges, keys or responses.

- [ ] **Step 1: Write failing tests** for `core.ts`: happy registration; wrong origin rejected; wrong challenge rejected; `uv` flag missing rejected; happy authentication returns the new counter; counter rollback detected by the DB rule (covered in Task 2, here assert `newCounter` value); assertion signed by a different key rejected.
- [ ] **Step 2:** Run `node core.test.mjs` → fails (module missing).
- [ ] **Step 3:** Implement `core.ts` and `index.ts` (CORS like the other functions).
- [ ] **Step 4:** Run tests → `ALL PASSED`.
- [ ] **Step 5:** Commit `feat(edge): webauthn function for device registration and punch tickets`.

### Task 4: Employee app

**Files:**
- Modify: `src/lib/types.ts` (AttendanceState gets `punch_window`, `biometric`), `src/lib/api.ts` (interface), `src/lib/supabaseApi.ts`, `src/lib/mockApi.ts`, `src/lib/errors.ts`, `src/screens/Home.tsx`, `src/styles.css` (only if a new class is needed)
- Create: `src/lib/biometric.ts` (`supportsPlatformAuthenticator(): Promise<boolean>`, `registerDevice(api): Promise<void>`, `fingerprintTicket(api, requestId: string): Promise<'ticket'|'unsupported'>`), `src/lib/punchWindow.ts` (`windowText(w: PunchWindow, tz: string): string | null`, `nextBoundaryMs(w: PunchWindow, serverNowMs: number): number | null`), `src/screens/DeviceSetup.tsx`
- Test: `src/lib/punchWindow.test.ts`, `src/lib/biometric.test.ts`, release check additions

**Interfaces:**
- Consumes: state keys from Tasks 1–2; Edge Function actions from Task 3.
- Produces: `WaqtiApi` gains `webauthn(action: 'register-options'|'register-verify'|'punch-options'|'punch-verify', body?: object): Promise<unknown>`; `punch(input)` sends `p_biometric`.

- [ ] **Step 1: Write failing unit tests:** `windowText` → «البصم متاح من 7:00 إلى 10:00» for `too_early`, «اليوم عطلة» for `day_off`, «انتهى وقت البصم لليوم» for `too_late` with no later window, `null` when allowed; `nextBoundaryMs` picks `opens_at` when not allowed and `closes_at` when allowed, using server time; `fingerprintTicket` returns `'unsupported'` when no platform authenticator, throws `AppError('biometric_failed')` with text «لم تتم البصمة» when the prompt is cancelled (`NotAllowedError`), and never calls `punch` in that case.
- [ ] **Step 2:** `npx vitest run` → new tests fail.
- [ ] **Step 3:** Implement. Home: button `disabled` when `!data.punch_window.allowed` with the line under it; re-load state at `nextBoundaryMs` (and the existing 30 s refresh). Before `api.punch`, when `biometric.policy==='required'`: no device and supported → show `DeviceSetup` («سجّل بصمتك لهذا الجهاز», one button); unsupported → note «هذا الجهاز لا يدعم البصمة؛ ستُعلَّم بصماتك للمراجعة» and punch with `'unsupported'`; device → `fingerprintTicket` then punch with the same `request_id`. Mock API implements both features with policy off by default and a switch for tests.
- [ ] **Step 4:** `npx vitest run` → all pass; `npx tsc -b` clean; build; release check (44) still passes and new checks pass: button disabled with the window text when the stub returns `allowed:false`; with policy required and a Playwright CDP virtual authenticator (`WebAuthn.enable` + `addVirtualAuthenticator` with `hasUserVerification:true, isUserVerified:true`) registration then a punch calls `webauthn` twice and `employee_punch` with the same request id; cancel (`isUserVerified:false`) shows «لم تتم البصمة» and no `employee_punch` call.
- [ ] **Step 5:** Commit `feat(app): punch windows and fingerprint before punching`.

### Task 5: Admin panel

**Files:**
- Modify: `waqti-admin/index.html` (one toolbar button «إعدادات البصم»), `waqti-admin/app.js`, `waqti-admin/export.js`, `waqti-admin/README.md`
- Test: `scratchpad/admin_check.py` additions, `scratchpad/xlsxtest/t3.js` additions

**Interfaces:**
- Consumes: `admin_get_punch_settings`, `admin_set_punch_settings`, `admin_set_employee_punch_windows`, `admin_remove_device`, profile keys `punch_windows`, `device`, list key `has_device`, attendance `authentication_method`, metadata `biometric`/`missed_checkout` via `needs_review` reasons.
- Produces: dialog «إعدادات البصم» (select «البصمة: معطّلة / إلزامية», checkbox «تقييد أوقات البصم», four number fields 0–720); employee dialog section with four fields (placeholder «قيمة الشركة») and «الجهاز المسجّل: … منذ …» + «إلغاء تسجيل الجهاز» (confirm dialog); `reviewLabel` adds «بدون بصمة» and «بدون خروج»; `AUTH_LABEL` already maps `biometric → بصمة`; the on-screen attendance list shows a small «بصمة» / «كلمة المرور» label under the movement badge, and the Excel «طريقة التحقق» column becomes on by default.

- [ ] **Step 1: Write failing checks:** settings dialog loads values and saves the six values (stub records the call); 721 refused in the form; employee dialog saves overrides through `admin_set_employee_punch_windows` with nulls for empty fields; device row shows and removal calls `admin_remove_device`; `reviewLabel({needs_review:true, location_status:'recorded', biometric:'unsupported'})` contains «بدون بصمة».
- [ ] **Step 2:** Run admin check and `node t3.js` → new checks fail.
- [ ] **Step 3:** Implement; ERRORS gets the six new codes plus `invalid_punch_settings`.
- [ ] **Step 4:** Admin check (131 + new) and `t.js`, `t2.js`, `t3.js` pass.
- [ ] **Step 5:** Commit; build `waqti_admin_11.zip`.

### Task 6: Release (only after Omar says «انشر»)

- [ ] **Step 1:** Production pre-checks: hashes of `record_punch`, `employee_punch`, `employee_attendance_state`, `admin_get_employee_profile`, `admin_list_employees` equal the local pre-migration copies.
- [ ] **Step 2:** `apply_migration` 8a then 8b; compare new hashes with local.
- [ ] **Step 3:** Production smoke test in one DO block that always raises (features switched on inside the transaction only): window refusal, unsupported punch flagged, ticket single use.
- [ ] **Step 4:** Deploy `webauthn` (verify_jwt true); deploy PWA to gh-pages; merge to main; send `waqti_admin_11.zip`.
- [ ] **Step 5:** Tell Omar how to switch the features on for a test company, and to test on one iPhone and one Android phone before clients.
