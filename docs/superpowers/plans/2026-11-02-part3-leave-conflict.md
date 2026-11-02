# Part 3 — Punch during approved leave + admin cancels the leave (phase15) Implementation Plan

> **For agentic workers:** executed inline (executing-plans). Steps use checkbox syntax.

**Goal:** a punch on a day covered by an approved leave is always saved, flagged for the admin; the admin either keeps the leave or cancels it (balance returns, employee is told).

**Architecture:** one migration `20261102170000_phase15_leave_conflict.sql` (+ ROLLBACK) replaces `private.record_punch` (from the phase 13 text) and `public.admin_review_queue` (adds a `leave jsonb` column), adds `private.approved_leave_on` and `public.admin_resolve_leave_conflict`. App: punch notice + cancelled-request note. Admin panel 12.5: two buttons on leave rows.

**Tech Stack:** Postgres/Supabase SQL (local suite `supabase/local/test-db.sh`), React+Vite+TS (vitest, Playwright mock), admin panel plain ES modules.

**Spec:** `docs/superpowers/specs/2026-11-02-onboarding-review-admins-handling-design.md` (Part 3).

## Global Constraints

- Nothing is applied to production or deployed without an explicit "نعم" from Omar for this part.
- The migration starts from the LATEST `record_punch` (phase 13 file) and the phase 14 `admin_review_queue`; it must keep `missing_checkin` handling and every other field.
- Balance is derived from approved requests (`private.leave_balance`): cancelling = `requests.status = 'cancelled'`, nothing else to restore.
- (Changed by Omar after the first delivery: the all-or-nothing rule is gone.) The admin cancels the days he picks, or all of them.
- Arabic RTL only. No service_role. Admin panel stays outside the repo (zip).

## Rulings (the spec is silent or ambiguous)

- R1 Flag only the FIRST punch of a local day on a leave (the check-out of the same day is not a second item). `keep_leave` applies to that day only; the next leave day flags again.
- R2 A day inside the leave range that is not a working day of the employee is not a conflict (`private.leave_days(emp, d, d) = 0`).
- R3 The approval rows of the cancelled request stay as history (who approved); only `waiting`/`pending` rows become `cancelled` (matters for the Part 5 handling step). The spec said "approval rows become cancelled": that would erase the record of who approved.
- R7 (Omar: "cancel specific days or all") `admin_resolve_leave_conflict(event, decision, note, days date[])`; `days` null = every working day. A request is one continuous range, so cancelling days in the middle SPLITS it: the first remaining part keeps the original request (shrunk), each later part is a new approved request (same type, same decision, finished approvals copied). Balance and every consumer of leave ranges (overlap check, reminders, overtime, attendance state) stay correct without being touched. The split parts are inserted already approved, so `enforce_leave_window` now skips non-pending inserts.
- R8 Only working days of the employee can be cancelled; a run made only of days off between cancelled days is not a part (no request with 0 days). Cancelling every working day = cancelling the request.
- R9 The admin may cancel days other than the day of the punch; the punch is resolved either way. In the panel the punch day is pre-selected.
- R10 Other flagged events of the leave follow the part that covers their day (their `leave_request_id` is repointed); a day no longer on leave is cleared when the leave was its only reason.
- R11 `decision_note` of the original/parts is replaced by the cancellation text (the previous note is kept in the audit log); the app shows the note on approved requests too.
- R4 On cancel, other events of the same leave that are still flagged only because of the leave are cleared automatically (otherwise the admin sees a conflict with a leave that no longer exists).
- R5 The old `admin_resolve_review(..., 'accept')` on a leave row still works (it leaves the leave as it is, like keep, without marking it).
- R6 "In-app notice" = the existing push notification (`request_decided`) + the reason in `requests.decision_note`, shown on the cancelled request card.

## Review Focus

- Leave that ends/starts at the day boundary in the company time zone (a punch at 23:30 or 00:30 local).
- Unpaid / sick / maternity leave also count.
- A pending (not approved) or rejected leave never flags.
- Two flagged events of one leave; cancelling through one clears the other when only the leave was the reason; keeps it when something else was also wrong (outside the zone).
- The same event resolved twice; another company's event; a non-admin.

### Task 1: Database (phase15)

**Files:**
- Create: `supabase/migrations/20261102170000_phase15_leave_conflict.sql`, `..._ROLLBACK.sql`
- Test: `supabase/tests/phase15_leave_conflict_tests.sql`

**Interfaces:**
- Produces: `private.approved_leave_on(p_employee uuid, p_date date) returns uuid`; `private.record_punch(...)` same signature, result JSON gains `on_approved_leave boolean`; events get `metadata.suspect += 'on_approved_leave'` and `metadata.leave_request_id`; `public.admin_review_queue(p_limit int)` gains column `leave jsonb` = `{request_id, leave_type, status, days, start_date, end_date}` or null; `public.admin_resolve_leave_conflict(p_event_id uuid, p_decision text, p_note text default null) returns jsonb` (`cancel_leave` | `keep_leave`; errors `invalid_action`, `not_found`, `already_resolved`, `not_leave_conflict`).

- [ ] **Step 1: write the failing tests** (names): flagged and saved on a leave day; check-out the same day not flagged again; result JSON `on_approved_leave`; pending leave / outside range / non-workday / rejected: not flagged; unpaid counts; queue row carries `leave`; keep_leave clears flag + audit + leave stays approved; cancel_leave: request cancelled, note + decided fields, balance back, push notification row, audit, sibling cleared only when leave was the only reason; invalid decision; resolve twice; cross-company; non-admin; accept still works.
- [ ] **Step 2: run, expect FAIL** (functions missing): `su postgres -c "bash /tmp/t11.sh"`.
- [ ] **Step 3: write migration + rollback.**
- [ ] **Step 4: run the file, expect all pass; then the full suite** (`cd supabase && su postgres -c "bash local/test-db.sh"`), expect `failed=0`.
- [ ] **Step 5: commit.**

### Task 2: Employee app

**Files:** `src/lib/types.ts`, `src/lib/attendance.ts` (+ test), `src/lib/mockApi.ts`, `src/screens/Requests.tsx`, `docs/PHONE_TEST.md`.

- [ ] **Step 1:** vitest `successNotice` for `on_approved_leave` (warning, mentions the leave and the review) — RED.
- [ ] **Step 2:** `PunchResult.on_approved_leave?: boolean`; notice text; mock `?onleave=1`. GREEN.
- [ ] **Step 3:** cancelled request card shows `decision_note`; Playwright mock check.
- [ ] **Step 4:** tsc + full vitest; commit.

### Task 3: Admin panel 12.5

**Files:** `js/review.js`, `export.js` (label), `js/core/errors.js`, `tests/rpc-inventory.test.mjs`, `tests/ui/fake-supabase.js`, `tests/ui/behavior.mjs`, README, version.

- [ ] **Step 1:** fake rows with `on_approved_leave` + `leave`; behavior checks (two buttons, no plain accept, confirm text names days, cancel/keep RPC args, list refresh) — RED.
- [ ] **Step 2:** implement. GREEN. Layout audit, screenshots looked at.
- [ ] **Step 3:** zip `waqti_admin_12_5.zip`, SendUserFile.

### Task 4: Close

- [ ] Self-review of the whole diff; commit + push; report in Arabic; ask Omar for "نعم" before applying phase15.
