# Onboarding, forgotten punches, leave review, second admin, handling step — design

Date: 2026-11-02 · Owner: Omar · Status: approved in chat (design), spec awaiting review

Five independent parts. Each has its own migration (if any), tests, and deploy. Order: 1 → 2 → 3 → 4 → 5.
Nothing is applied to production or deployed without an explicit "نعم" from Omar for that part.

## Decisions already taken (from Omar)

- Fingerprint at first login follows the **company policy** (`biometric_policy = 'required'`), not a global rule.
- "Check-out without check-in" is reported to the admin **inside the admin panel only** (red counter + review list). No push, no email.
- After the **last approval** the requesting employee gets the normal "approved" notice. The handling step is **internal**: the requester never sees it and gets no notice about it.
- Leave stays "deducted" at the last approval. (The balance is derived from approved requests, so there is no separate deduction to undo.)
- Cancelling an approved leave is all-or-nothing (no partial shortening in this round).

## Part 1 — First login (app only, no DB change)

Flow: sign in with temporary password → **new password** → **fingerprint registration (only if policy is `required` and this account has no device)** → home.

- `ChangePassword`: add a hidden, read-only `<input type="email" autocomplete="username" value={email}>` so Android (Google Password Manager) and iOS (iCloud Keychain) save the new password under the right user. Password fields use `autocomplete="new-password"`. The email is always filled from the session, never typed.
- `Login`: remember the last used email on the phone (localSettings, key per device, not secret) and pre-fill it. Input has `autocomplete="username"`, `inputmode="email"`, no auto-capitalise/auto-correct. The password input has `autocomplete="current-password"`.
- New gate in `App.tsx` after `mustChangePassword`: `needsDevice` = policy `required` AND no registered device AND platform authenticator supported. When true, show `DeviceSetup` full screen (no home, no tabs). If the phone does not support a platform authenticator: show a clear message and continue; punches are flagged "بدون بصمة" as today (server already does this).
- The state needed (policy, has_device) is already in `employee_attendance_state().biometric`; the gate reads it once at start (one call), and again after `DeviceSetup` succeeds.
- iOS note shown inside `DeviceSetup` when running in a normal Safari tab (not installed): fingerprint/Face ID needs the app opened from the home screen icon. Detected with `navigator.standalone === false` on iOS user agents. This is an assumption about iOS behaviour and **must be checked by hand on a real iPhone and a real Android phone** (cannot be tested in this environment).
- Offline/slow network at the gate: show retry, never let the employee through to the home screen by accident when the policy is unknown (fail closed only for the fingerprint gate; the password gate already fails closed).
- Tests: vitest for the gate decision (pure function `nextGate(user, bio, supported)`); Playwright mock runs for: first login (password → fingerprint → home), policy off (password → home), unsupported device (message → home), returning user (login prefilled, no gates).

## Part 2 — Button flips to check-out + review of "check-out without check-in" (migration phase14)

Server decides the **next action** in `employee_attendance_state()`:

- Open session → `check_out` (as today).
- No open session, **check-in window is closed (`too_late`)**, **check-out window is open**, and the last punch is not a check-out today → `next_action = 'check_out'`, `forgot_check_in = true`. The main button reads "تسجيل الانصراف" with a sub-line "لم يُسجَّل حضورك — تظهر الحركة للمراجعة". Pressing it goes through the existing phase-13 path (`record_punch` already accepts it, flags `missing_checkin`).
- No open session and the check-in window is still open → `check_in` (as today); the phase-13 small link stays as a fallback.
- Punch windows turned off, or no schedule → unchanged (button stays check-in; the small link stays).
- `can_check_out_without_in` stays for the fallback link.
- Admin panel: attendance list already shows a "للمراجعة" badge with the reason. Add: a red counter on the attendance tab for open review items, a filter "للمراجعة فقط", reason label `انصراف بدون حضور مسجّل` (already added in admin 12.3).
- Resolve action for the admin (new RPC `admin_resolve_review(p_event_id, p_action, p_time, p_note)`): `accept` (clears `needs_review`) or `add_check_in` (inserts the missing check-in at a given time before the check-out, same day, creates and closes the session). Both write `audit_write`. Time order and company scoping are checked.
- Tests (SQL): flip only when window closed/open as described; no flip with windows off; second check-out refused; resolve accept; resolve add_check_in builds a closed session; cross-company refused.

## Part 3 — Punch during approved leave + admin cancels leave (migration phase15)

- `private.record_punch`: if the employee has an **approved leave** covering the punch's local date → the punch is saved (never blocked), `needs_review = true`, `metadata.suspect += 'on_approved_leave'`. Admin label `حضور أثناء إجازة معتمدة`.
- `public.admin_resolve_leave_conflict(p_event_id, p_decision, p_note)`:
  - `cancel_leave` → the leave request becomes `cancelled`, its approval rows become `cancelled`, the event's `needs_review` is cleared; the balance returns by itself (derived). The employee gets an in-app notice "أُلغيت إجازتك بسبب تسجيل حضورك".
  - `keep_leave` → event stays recorded, `needs_review` cleared, marked as ignored in metadata.
  - Both write `audit_write` with the request id.
- Not in scope: partial shortening, pay/overtime effects of working during leave.
- Tests (SQL): punch on leave day flagged and still saved; no flag outside the range; cancel restores the balance; keep clears flag; cross-company refused; non-admin refused.

## Part 4 — Another system admin (migration phase16)

- Admin = row in `company_members` with `role = 'company_admin'` whose employee is active. New RPCs, all behind `require_company_admin()`:
  - `admin_list_admins()` → admins of my company (name, number, since).
  - `admin_add_admin(p_employee_id)` → promotes an **existing active employee** of my company. A brand-new person is first created from the Employees page (existing Edge Function), then promoted. No service_role use.
  - `admin_remove_admin(p_employee_id)` → refused if it is the **last admin** or **myself**.
  - All write `audit_write` (`admin.added`, `admin.removed`).
- A newly promoted admin must still have a changed (non-temporary) password: `require_company_admin()` already enforces this.
- Admin panel: new settings pane "مديرو النظام" (list, add from employee picker, remove with confirm).
- Tests (SQL): add/remove; last admin and self removal refused; other company's employee refused; inactive employee refused; non-admin refused; audit rows written.

## Part 5 — Handling step in the approval path (migration phase17)

- New step kind `handler` in `approval_steps` and `request_approvals` (`approver_kind` check extended). Rules: exactly one specific employee (`approver_employee_id` required), must be the **last** step, at most one per path.
- Flow: after the last normal approval → request `status = 'approved'` (requester notified as usual, leave counted), and a `handler` row becomes `pending`. The handler sees it in the existing approver inbox under a "للتنفيذ" label. Button "تم التنفيذ" + note → handler row `done`. The requester gets **no** notice and sees **no** extra status.
- Request JSON for the requester hides `handler` rows. Approver/admin views show them.
- If the handler is inactive, equal to the requester, or missing: the handler step is skipped (same skip rule as other steps).
- Admin panel: the approvals editor offers "تنفيذ (موظف محدد)" as the last step only.
- Existing in-flight requests keep their old path.
- Tests (SQL): path validation (last only, one only, needs employee); approval flow ends in `approved` + pending handler; requester JSON hides handler; handler can mark done; others cannot; skipped when handler invalid; rollback file.

## Cross-cutting

- Every migration has a `_ROLLBACK.sql`, a guard block, and a SQL test file; the full local suite must stay green (`supabase/local/test-db.sh`).
- Migrations that replace a function must start from the **latest** definition in the repo (lesson from phase 13: the phase-10 `login_enabled` field was almost lost).
- Arabic RTL only; no new hidden dependencies; admin panel stays outside the repo, delivered as a zip with a version bump and README note.
- Real-device checks Omar must do (cannot be done here): fingerprint registration + login on one Android phone and one iPhone (installed from the home screen), password-manager save prompt on both.

## Out of scope

Push/email to admins, partial leave shortening, creating a brand-new person inside "add admin", the profile-visibility feature (waiting for Omar).
