# Fingerprint check and punch windows: design

- **Date:** 2026-11-01 · **Status:** written, waiting for Omar's review
- **Branch:** `security-fixes` (waqti-app and waqti-admin)
- **Related:** security audit R1 (`.security-audit/FINDINGS.md`, kept local). The security fixes SEC-001…SEC-012 are bounded and approved in chat; they are implemented on the same branch and are not part of this spec, except where they meet it (offline punching removed, review flags shown to admins).

## 1. Intent (agreed in chat, 2026-11-01)

| | |
|---|---|
| Goal of the fingerprint | Stop **buddy punching**: an employee who knows a colleague's password must not be able to punch for them from his own phone. |
| Fingerprint scope | A **company setting**: off / required. When required, each employee registers one device; every check-in and check-out needs a fresh fingerprint (or the phone's own screen lock) on that device. |
| Phone that cannot do it | **Allowed, but flagged**: the punch is saved with `needs_review` and shown as «بدون بصمة». |
| Punch windows | Set by the system admin, **per employee**, with company defaults. Outside the allowed times the punch button is **disabled**, and the server refuses the punch as well. |
| Overtime | An overtime assignment opens its own window, so the employee can punch in and out for the overtime period. |
| Offline punching | Removed (decision on SEC-001). Every punch needs a connection. |

**Assumptions I made (Omar did not state them; correct me):**

1. An employee with **no work schedule at all** has no window limits until the admin adds a schedule.
2. A **missed check-out window** does not lock the employee: the open session is closed automatically as «بدون خروج» (no check-out time) and flagged for review, so the next check-in is possible.
3. **One registered device per employee.** Changing phones = the admin removes the old device in the panel, then the employee registers the new one.
4. Window values are minutes, 0 to 720.

**What the fingerprint does not prove (to be told to client companies):** WebAuthn proves that the person unlocked *the registered phone* with its own lock (fingerprint, face or the phone PIN — the web cannot force fingerprint only). It does not prove *whose* finger it was. Passkeys may sync to the employee's other devices through their Apple or Google account. It stops buddy punching from another person's phone; it does not stop an employee from handing over his unlocked phone.

## 2. Fingerprint (WebAuthn, verified on the server)

### Why server verification

A check done only in the browser can be skipped with the developer tools, exactly like the location today. So the server issues the challenge and checks the signature; the database refuses a punch without a valid, unused ticket.

### Data (new migration `phase8_biometric_windows`)

- `companies.biometric_policy text not null default 'off' check (in ('off','required'))`
- `public.webauthn_credentials` (RLS on, no policies, no grants):
  `id uuid pk`, `company_id`, `employee_id` (unique — one device per employee), `credential_id text unique`, `public_key bytea`, `sign_count bigint`, `transports text[]`, `device_label text` (from the user agent, ≤ 120 chars), `created_at`, `last_used_at`.
- `private.webauthn_challenges`: `employee_id`, `purpose ('register','punch')`, `challenge text`, `expires_at` (now + 2 min), one row per employee and purpose (upsert).
- `private.punch_tickets`: `employee_id`, `request_id uuid` (the punch's own request id), `expires_at` (now + 2 min), `used_at`. Primary key `(employee_id, request_id)`.

### Edge Function `webauthn` (verify_jwt on)

One function, four actions, using `@simplewebauthn/server` (pinned version):

| Action | Who | Does |
|---|---|---|
| `register-options` | active employee, company policy `required`, no device yet | stores a challenge, returns creation options (RP ID `omarkraym.github.io`, `userVerification: required`, `authenticatorAttachment: platform`, `residentKey: preferred`) |
| `register-verify` | same | verifies the attestation against the stored challenge and origin `https://omarkraym.github.io`, stores the credential, audit `device.register` |
| `punch-options` | active employee with a device | stores a challenge, returns request options limited to that credential |
| `punch-verify` | same; body has the assertion and the punch `request_id` | verifies signature, challenge, origin, RP ID, user-verified flag and that `sign_count` did not go backwards (when the device reports one); updates `sign_count`, `last_used_at`; inserts a punch ticket for `request_id` |

The function reads the caller from their JWT and the database (`require_active_employee` through service-role RPCs written for it), never from the body. Service-role helper RPCs are granted to `service_role` only.

### Punch rule (in `private.record_punch`)

When the company policy is `required`:

- employee **has a device** → the punch needs an unused, unexpired ticket for `(employee, request_id)`; it is marked used in the same transaction. Otherwise `biometric_required` is raised. `authentication_method = 'biometric'`.
- employee **has no device** and the app reports the phone cannot do WebAuthn (`p_biometric = 'unsupported'`) → saved with `needs_review = true`, `authentication_method = 'password'`, `metadata.biometric = 'unsupported'`.
- employee **has no device** and the phone can do it → `device_not_registered`; the app shows the registration step first.
- once a device is registered, `p_biometric = 'unsupported'` is refused (`biometric_required`): the flag is only for accounts that never registered.

`p_biometric` is a new optional argument of `employee_punch` (`'ticket'` default, or `'unsupported'`). The app's claim that the phone is unsupported cannot be proven; that is why such punches are always flagged for review.

When the policy is `off`, nothing changes (`authentication_method = 'password'`).

Known weakness, accepted in chat: someone who has a colleague's password and registers *first* can bind his own phone to that account. Mitigation: the admin sees device name and date per employee and can remove it; registration is in the audit log.

### Employee app

- After sign-in, if the company requires it and no device is registered: a short screen «سجّل بصمتك لهذا الجهاز» with one button; unsupported phones see «هذا الجهاز لا يدعم البصمة؛ ستُعلَّم بصماتك للمراجعة» and continue.
- On the punch button: request options → `navigator.credentials.get` → `punch-verify` → `employee_punch` with the same `request_id`. Cancelling the fingerprint prompt shows «لم تتم البصمة» and records nothing.
- Library: `@simplewebauthn/browser` (pinned).

### Admin panel

- Company settings: «البصمة: معطّلة / إلزامية».
- Employee profile: «الجهاز المسجّل: <device> منذ <date>» + «إلغاء تسجيل الجهاز» (RPC `admin_remove_device`, audit `device.remove`).
- Attendance list and Excel: «طريقة التحقق» column (بصمة / كلمة المرور / بدون بصمة).

## 3. Punch windows

### Data

- `companies.punch_windows_enabled boolean not null default false`
- `companies.in_before_min, in_after_min, out_before_min, out_after_min smallint not null` (defaults 60, 120, 120, 60; 0–720)
- `employees.in_before_min, in_after_min, out_before_min, out_after_min smallint null` (null = company value)
- `attendance_session_status` gets a third value `missed_checkout`; the status check becomes: `open` ⇒ no check-out event, `closed` ⇒ has one, `missed_checkout` ⇒ none.

### Rule — one function `private.punch_window(employee, at)` used by the punch and by the app state

Returns `allowed boolean`, `action`, `opens_at`, `closes_at`, `reason` (`no_limits`, `shift`, `overtime`, `day_off`, `too_early`, `too_late`).

- Feature off, or the employee has no schedule rows → allowed, `no_limits`.
- **Check-in** allowed in `[shift_start − in_before, shift_start + in_after]` of today's shift, or `[ot.start − in_before, ot.start + in_after]` of an active (`assigned`) overtime assignment.
- **Check-out** allowed in `[shift_end − out_before, shift_end + out_after]` of the session's shift, or the matching window around the overtime end.
- Shifts that end after midnight (`end_time <= start_time`) end on the next day; yesterday's shift is considered too, so a night worker can check out after midnight.
- Non-workday with no overtime → `day_off`.

`private.record_punch` calls it with the server time and raises `outside_punch_window` (message carries the next opening time) when not allowed.

### Missed check-out

At the start of `record_punch` and of `employee_attendance_state`: an open session whose check-out window has closed (and no overtime window is open) is set to `missed_checkout` and its check-in event gets `needs_review = true`. The next action is then check-in. No time is invented for the missing check-out.

### Employee app

- `employee_attendance_state` returns `punch_window: { allowed, opens_at, closes_at, reason }`.
- The punch button is disabled when `allowed` is false, with one line under it: «البصم متاح من 7:00 إلى 10:00» / «اليوم عطلة» / «انتهى وقت البصم لليوم». The app re-reads the state when the window opens or closes (timer to the next boundary, and every minute as a fallback).

### Admin panel

- Company settings: switch «تقييد أوقات البصم» + four numbers.
- Employee profile: the same four numbers, empty = «قيمة الشركة».
- Attendance list: sessions closed as «بدون خروج» shown with the review flag.

## 4. Errors (Arabic text in `src/lib/errors.ts` and the panel's `ERRORS`)

`biometric_required`, `device_not_registered`, `device_already_registered`, `biometric_failed`, `outside_punch_window` («البصم غير متاح الآن»), `day_off`.

## 5. Testing

- **DB tests** (`supabase/tests/phase8_*.sql`, run on the local replica): window edges (one minute inside and outside each edge), per-employee override vs company default, overtime window on a day off, night shift across midnight, missed check-out auto-close and the next check-in, ticket required / single use / expired / another employee's ticket / other request_id, unsupported-device flag, policy off unchanged, cross-company admin calls refused.
- **Edge Function tests** (Deno test with a software authenticator): wrong origin, wrong challenge, reused challenge, sign-count rollback, user-verified flag missing.
- **Browser**: Playwright with a CDP virtual authenticator for register + punch; button disabled outside the window; the release check (42) and admin check (118) still pass.

## 6. Out of scope

Hardware fingerprint terminals; face matching; per-department windows; manual attendance correction requests (suggested as the follow-up for people who cannot punch because of no connection).

## 7. Rollout

1. Migration on production with both features **off** for every company (no behaviour change).
2. Deploy the `webauthn` function and the PWA.
3. Omar turns them on for a test company, tests on real iPhone and Android phones, then for clients.
