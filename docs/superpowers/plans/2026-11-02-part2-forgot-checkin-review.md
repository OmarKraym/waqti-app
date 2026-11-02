# Part 2 — Button flips to check-out; admin review of "check-out without check-in" — Plan

> Executed inline (native). Spec: `docs/superpowers/specs/2026-11-02-onboarding-review-admins-handling-design.md` (Part 2).

**Goal:** When an employee forgot to check in and the check-in window is over but the check-out window is open, the main button becomes "تسجيل الانصراف" (flagged for review). The admin sees a red counter and a review list in the attendance tab and decides: accept, or add the missing check-in.

## Rulings made while planning
- Flip condition ignores the `punch_window` reason (`too_late` in the spec): `no open session AND check-in window not allowed AND check-out window allowed AND last punch not a check-out today`. Reason: with night shifts the check-in window reason is `too_early` at 05:30 although the previous shift's check-out window is open. Cost if wrong: a rare extra flip; the server still flags the punch for review.
- Review queue = new RPC `admin_review_queue` (no change to `admin_list_attendance`, whose signature was replaced three times already).
- The admin panel gets a card inside the attendance tab, not a new tab.

## Tasks
1. **Migration `20261102160000_phase14_forgot_checkin_review.sql` (+ROLLBACK, + `tests/phase14_forgot_checkin_review_tests.sql`)**
   - `public.employee_attendance_state()` (from the phase 13 text): `forgot_check_in boolean`; `next_action`/`punch_window` follow the flip.
   - `public.admin_review_queue(p_limit int default 200)` → rows `(event_id, employee_id, employee_number, full_name, event_type, occurred_at, location_status, suspect text[], biometric text, missed_checkout boolean, offline boolean, sync_delay_s int, needs_review boolean, review_total bigint)`, only `needs_review` events of my company, newest first.
   - `public.admin_resolve_review(p_event_id uuid, p_action text, p_time timestamptz default null, p_note text default null) returns jsonb` — `accept` clears the flag; `add_check_in` (only for a check-out with `suspect ∋ missing_checkin`) inserts an admin check-in at `p_time` (same local day, before the check-out, after the employee's previous event), a closed session, clears the flag; both write `audit_write` and mark `metadata.review`. Errors: `invalid_action`, `not_found`, `already_resolved`, `invalid_time`.
   - Tests (SQL): flip only when check-in window closed and check-out window open; no flip with windows off; no flip after a check-out today; night-shift case; queue lists only my company's flagged events; accept; add_check_in builds a closed session; invalid time cases; second resolve refused; cross-company and non-admin refused.
2. **App:** `AttendanceState.forgot_check_in?`; `applyResult` clears it; mock `?forgot=1`; `Home.tsx`: main button sub-line "لم يُسجَّل حضورك — تظهر الحركة للمراجعة", never queued offline, the small phase-13 link hidden when the main button already flipped. Vitest + Playwright (`forgot-check.mjs`).
3. **Admin 12.4:** review card in the attendance tab + count on the tab button; "قبول" and "إضافة الحضور" (time input) with confirm; `rpc-inventory` test updated; fake-supabase; README; zip.
4. **Close:** full local DB suite, vitest, admin tests, harness; commit and push; ask Omar for "نعم" before applying phase 14 to production and deploying.
