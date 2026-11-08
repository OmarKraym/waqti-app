# Phase 2 (database phase 21) — work places, deleting an employee, install button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) an employee can only be given an existing work place (no "add place" in his form); (2) a work place can be deleted safely; (3) an employee can be deleted safely (soft delete, history kept); (4) the employee app shows an "install the app" button; (5) **added by Omar 2026-11-08:** a forgotten check-out is recorded from the review window with a button «إضافة الانصراف» that works exactly like «إضافة الحضور» (it corrects the flagged movement and closes its session), and the check-out option leaves the «إضافة حضور أو خروج» dialog of the attendance tab.

**Architecture:** one small migration (`phase20c`) adds the action `add_check_out` to `admin_resolve_review`; one migration (`phase21`) adds `deleted_at` to `work_locations` and `employees` plus two admin functions (`admin_delete_work_location`, `admin_delete_employee`) and re-creates two list functions to hide deleted rows. The panel gets two dialogs and two small pure libraries; the app gets one pure library and one button. Nothing is hard-deleted; every deletion is audited.

**Tech Stack:** Postgres/Supabase (plpgsql, local test runner `supabase/local/test-db.sh`), admin panel (plain JS ES modules, node:test + Playwright with a fake Supabase), employee app (React/Vite/TS, vitest).

**Spec:** `docs/superpowers/specs/2026-11-08-waqti-modernization-design.md` §2 «المرحلة 2» (approved 2026-11-08).

## Global Constraints

- No production migration, deploy or push without Omar's explicit «نعم» / «ارفع», one part at a time. Local only until then.
- Company isolation and the admin check live in the database (`security definer`, `require_company_admin()`); another company's id → `not_found`.
- **No hard delete of history.** Deleting = `deleted_at` + `is_active = false` (employee) or `deleted_at` (place). Attendance, requests, audit rows stay.
- The admin panel stays outside the repo (zip `waqti_admin_12_18.zip`); version bump 12.17 → 12.18.
- Arabic UI, RTL, short sentences. Tests are never counted as passed unless run.
- Existing signatures keep working: an older panel/app against the new database must not break (the new list columns are appended; `admin_list_employees()` keeps its columns).

## Review Focus

1. A place whose only employees are inactive or deleted can be deleted without a move target; those employees keep pointing at it (history). *Test in Task 1.*
2. A place can be added again with the name of a deleted one (the unique name index must ignore deleted places). *Task 1.*
3. A deleted employee's attendance, requests and audit rows still appear in `admin_list_attendance` / `admin_list_requests` with his name, and Excel export still names him. *Tasks 1 and 3.*
4. A deleted employee cannot punch, log in to a usable state or receive push; his phone binding and push subscriptions are gone. *Task 1.*
5. Refusals that protect other people: he is someone's direct manager, he has an open session, he has pending requests, he is an admin, he is the caller. Each has its own code and its own Arabic sentence. *Tasks 1 and 3.*
6. Two admins deleting the same employee/place at once, or deleting a place while another admin moves an employee into it (row locks). *Task 1.*
7. The typed name must match exactly (after trim and collapsing spaces); a wrong name must never delete. The server checks it, not only the dialog. *Tasks 1 and 3.*
8. `add_check_out` only works on a check-in that is flagged and marked «missed check-out»; on anything else it is `invalid_action`. It refuses a time that is not after the check-in, more than 24 h after it, in the future, or with another event of the employee in between. The time of day typed earlier than the check-in's means the next day (night shift). *Tasks 5 and 6.*
9. Nothing is lost by taking `check_out` out of the general dialog: a check-in added from it on an earlier day becomes a flagged «missed check-out» row in the review card, where the new button finishes it. *Task 6.*

**Execution order (set 2026-11-08 after Omar's addition): Task 5, Task 6, then Tasks 1, 2, 3, 4, then Task 7.** The small check-out change goes first; the task numbers only name the tasks.

## Rulings made while planning (change any before work starts)

- R1. The employee **number and e-mail stay reserved** after deletion (unique constraints and the auth user remain). Reusing them would mean editing history. The dialog says so.
- R2. Deleting an employee is **refused**, not worked around, when he has an open session (use «إضافة خروج», phase 20), pending requests, or reports to him as direct manager. The admin resolves those first.
- R3. An admin cannot be deleted (remove the admin role first) and nobody can delete himself.
- R5. (Omar, 2026-11-08) The check-out is recorded **only from the review window** (action `add_check_out` of `admin_resolve_review`, mirror of `add_check_in`). The dialog «إضافة حضور أو خروج» becomes «إضافة حضور» (check-in only, for a day where nothing was recorded). `admin_add_punch` stays in the database unchanged (it already supports a check-out; the panel simply no longer offers it).
- R6. The review check-out is saved as a correction (`source: admin_correction`, `corrects_event`), like the check-in one, and audited as `attendance.review_add_check_out`; its time limits are the ones of phase 20 (after the check-in, at most 24 h, not in the future, nothing in between).
- R4. Deleting a place with active employees requires choosing another place to move them to; the move copies the new place's geofence the same way `admin_save_employee_profile` does.

---

### Task 1: Database — soft delete for places and employees (migration 21)

**Files:**
- Create: `supabase/migrations/20261109100000_phase21_workplaces_delete_employee.sql`, `..._ROLLBACK.sql`
- Test: `supabase/tests/phase21_workplaces_delete_employee_tests.sql`

**Interfaces:**
- Produces:
  - `work_locations.deleted_at timestamptz`, `employees.deleted_at timestamptz` (null = live).
  - unique index on place names becomes partial: `(company_id, lower(btrim(name))) where deleted_at is null`.
  - `admin_list_work_locations()` → existing columns + `active_count bigint` appended; hides deleted places; `employees_count` counts live (not deleted) employees.
  - `admin_list_employees()` → same columns, hides `deleted_at is not null`.
  - `admin_delete_work_location(p_location_id uuid, p_move_to uuid default null)` → `{deleted: true, moved: <n>}`. Errors (P0001): `not_found`, `has_employees` (active employees and no target), `invalid_target` (same place, deleted, other company).
  - `admin_delete_employee(p_employee_id uuid, p_confirm_name text)` → `{deleted: true}`. Errors: `not_found`, `name_mismatch`, `is_admin`, `self_delete`, `open_session`, `pending_requests`, `has_reports` (22023 or P0001 as the neighbouring functions do).
  - audit actions `work_location.delete`, `employee.delete`.
- Consumes: `require_company_admin()`, `audit_write(...)`, `admin_remove_device(uuid)`, tables `push_subscriptions`, `employee_managers`/approval chain tables (read their names first), baseline `admin_save_employee_profile` for how a place's geofence reaches an employee (`employee_geofences.source_location_id`).

- [ ] **Step 1: Write the failing test file** covering every error code, the success paths, and Review Focus 1, 2, 3, 4, 6, 7 (two employees + two places + another company; assertions listed in the Review Focus, plus: `admin_list_employees` hides the deleted employee while `admin_list_attendance` still returns his rows; the deleted employee's `employee_attendance_state()` raises; device binding and push subscriptions are gone; audit rows exist; a place with only inactive employees deletes without a target).
- [ ] **Step 2: Run it, expect FAIL** (`TESTS=tests/phase21_workplaces_delete_employee_tests.sql bash local/test-db.sh` from `supabase/`): "column deleted_at does not exist".
- [ ] **Step 3: Write the migration** with a guard block (phase 20 functions exist), additive columns, the partial index swap, the two list functions (drop + create only where the return type changes), the two delete functions (lock the rows `for update` in the employee-first order used by `record_punch`; call `admin_remove_device`; delete the employee's `push_subscriptions`), grants (`authenticated` only).
- [ ] **Step 4: Run the test file, expect all PASS**, then the whole suite (`bash local/test-db.sh`): previous TOTAL 1118 must still pass.
- [ ] **Step 5: ROLLBACK file** (restore the two list functions from their previous versions, drop the two functions, drop the columns, restore the old index) and prove it: apply all, run the rollback, run the older tests, apply again, compare the fingerprint.
- [ ] **Step 6: Mutation checks** (about 20: each error check removed, the `where deleted_at is null` removed from each list, the name comparison loosened, the lock removed, the move not applied): every one must fail the tests; tighten tests for survivors.
- [ ] **Step 7: Commit** (local): `git add supabase/ && git commit -m "Phase 21: soft delete for work places and employees"`.

### Task 2: Panel — the employee form only picks an existing place

**Files:**
- Modify: `waqti-admin/js/employee-form.js` (remove `newLoc`, `addLocBtn`, `addLocation`, the `.inline-add` row; add the "no places yet" hint with a button that opens الإعدادات ← أماكن العمل والنطاقات)
- Test: `waqti-admin/tests/ui/behavior.mjs` (+ `fake-supabase.js` if needed)

**Interfaces:** Consumes `S.workLocations` (unchanged). Produces nothing new.

- [ ] **Step 1: Failing behaviour test:** the form has no input named "اسم مكان عمل جديد" and no `admin_add_work_location` call is possible from it; with zero places the hint shows and saving is blocked with a clear message; with places the select works as before (the employee is saved with the chosen id).
- [ ] **Step 2: Run `node tests/ui/behavior.mjs .`, expect those checks FAIL.**
- [ ] **Step 3: Implement the removal and the hint.**
- [ ] **Step 4: Run behaviour + `npm test`, expect PASS** (rpc inventory test still lists `admin_add_work_location` because the settings pane uses it).
- [ ] **Step 5: Commit** is not possible (the panel is outside git): note the files in the CHANGELOG instead.

### Task 3: Panel — delete a place, delete an employee

**Files:**
- Create: `waqti-admin/js/lib/deletion.js` (pure: `nameMatches(typed, full)`, `placeDeleteState(place)`, `deleteErrorText(e)`), `waqti-admin/js/employee-delete.js` (dialog), `waqti-admin/tests/deletion.test.mjs`
- Modify: `waqti-admin/js/settings/places.js` (delete button per row + dialog with the move-to select when `active_count > 0`), `waqti-admin/js/employees.js` or the employee form (entry point «حذف الموظف»), `tests/rpc-inventory.test.mjs` (+2 functions), `tests/ui/fake-supabase.js`, `tests/ui/behavior.mjs`

**Interfaces:**
- Consumes: Task 1 functions and error codes.
- Produces: `nameMatches(typed: string, full: string): boolean` (trim, collapse spaces, exact otherwise); `deleteErrorText(e): string | null` with one sentence per code of Task 1.

- [ ] **Step 1: Failing unit tests** for the three helpers (every code has its own sentence; `nameMatches` exactness incl. extra spaces; `placeDeleteState` says "needs a target" / "can delete" / "nothing to move").
- [ ] **Step 2: Run `npm test`, expect FAIL** (module missing).
- [ ] **Step 3: Implement the library**, then the two dialogs: the delete button stays disabled until the typed name matches; the dialog shows the employee's name, what happens (history kept, account stopped, phone released, number and e-mail stay reserved), and the server's refusal in plain words; a wrong server name still shows `name_mismatch`.
- [ ] **Step 4: Failing behaviour tests, then green:** place with employees asks for a target and sends `p_move_to`; place without active employees deletes at once after confirm; employee dialog: button disabled / enabled, sends `p_confirm_name`, list reloads, a refusal keeps the dialog open with its sentence; "function not found" shows the "not available yet" sentence.
- [ ] **Step 5: Run all three panel suites** (`npm test`, `behavior.mjs`, `layout.mjs --scenario v12`, ~4 min) and mutation-check the dialogs (name check removed, target not sent, list not reloaded, error text table, button not re-enabled).

### Task 4: App — "install the app" button

**Files:**
- Create: `src/lib/install.ts` (pure state + event wiring), `src/lib/install.test.ts`
- Modify: `src/screens/Home.tsx` (button in the top area), `src/styles.css`, `src/lib/mockApi.ts` (flag `install=1` to simulate the prompt)

**Interfaces:**
- Produces: `installState(e: { standalone: boolean; isIos: boolean; hasPrompt: boolean; installed: boolean }): "hidden" | "prompt" | "ios"` and a small store that captures `beforeinstallprompt` (calls `preventDefault`, keeps the event) and clears on `appinstalled`.
- Consumes: the standalone/iOS detection already in `src/lib/push.ts` and `firstRun.ts` (`iosBrowserTab`) — reuse it, and reuse the existing "Share → Add to Home Screen" wording; do not add a second iOS hint.

- [ ] **Step 1: Failing unit tests:** installed app (`standalone`) → hidden; Android/desktop Chrome with a captured prompt → `prompt`; iPhone/iPad in Safari → `ios`; after `appinstalled` → hidden; no prompt and not iOS → hidden (never a dead button); declining the native prompt hides the button for the session.
- [ ] **Step 2: Run `npx vitest run src/lib/install.test.ts`, expect FAIL.**
- [ ] **Step 3: Implement** the library and the button (a calm line at the top of Home, dismissible, hidden in the installed app); tapping it calls `prompt()` on Android/Chrome, or opens the existing iOS instruction.
- [ ] **Step 4: Full app checks:** `npx vitest run` (352 + new), `npx tsc -b`, `npm run build`; look at it in the browser with the fake server at 360 px (`?install=1`) and once as standalone (no button).
- [ ] **Step 5: Commit** (local).

### Task 5: Database — `add_check_out` in `admin_resolve_review` (migration 20c)

**Files:**
- Create: `supabase/migrations/20261108150000_phase20c_review_add_check_out.sql`, `..._ROLLBACK.sql` (puts the phase 14 version back)
- Test: `supabase/tests/phase20c_review_add_check_out_tests.sql`

**Interfaces:**
- Produces: `admin_resolve_review(p_event_id, p_action, p_time, p_note)` accepts `'add_check_out'` (same signature, same return keys plus `check_out_event_id`; `accept` and `add_check_in` behave exactly as before). Errors: `invalid_action` (not a flagged missed-check-out check-in), `invalid_time`, `already_resolved`, `not_found`.
- Consumes: phase 14 body of `admin_resolve_review`; `attendance_sessions` status `missed_checkout`; the flag `metadata.missed_checkout`.

- [ ] **Step 1: Failing tests:** a check-in made `missed_checkout` by `close_missed_checkout` (and one made by `admin_add_punch`): `add_check_out` adds an `admin` check-out with `source admin_correction` and `corrects_event`, closes that exact session, resolves the flagged check-in (`needs_review` false, `missed_checkout` false, `review` object), audits `attendance.review_add_check_out`; each refusal of Review Focus 8; two flagged check-ins on one day close their own sessions; `accept` and `add_check_in` results unchanged (the phase 14 tests keep passing).
- [ ] **Step 2: Run, expect FAIL** (`invalid_action` for the new action).
- [ ] **Step 3: Write the migration** (guard; `create or replace` of the phase 14 function plus the new branch; same lock order).
- [ ] **Step 4: Run the new file, then the whole suite, expect PASS.**
- [ ] **Step 5: ROLLBACK proof and about 10 mutations** (branch condition loosened, time limits removed, session not closed, flag not cleared, other session closed, audit missing).
- [ ] **Step 6: Commit** (local).

### Task 6: Panel — «إضافة الانصراف» in the review window; the general dialog is check-in only

**Files:**
- Modify: `waqti-admin/js/review.js` (button + `openAddCheckOut(r)`), `waqti-admin/js/lib/review-time.js` (+ `checkOutIso`), `waqti-admin/js/manual-punch.js` and `js/lib/manual-punch.js` (check-in only: no kind select, texts updated, toast points to the review card), `waqti-admin/index.html` (button text «إضافة حضور»), `tests/review-time.test.mjs` (new or extended), `tests/manual-punch.test.mjs`, `tests/ui/fake-supabase.js`, `tests/ui/behavior.mjs`

**Interfaces:**
- Produces: `checkOutIso(checkInIso: string, hhmm: string, dayOf, offset): string | null` — the typed time on the check-in's day, or on the next day when it is not later than the check-in's time.
- Consumes: Task 5 (`admin_resolve_review(..., 'add_check_out', at, note)`) and the queue column `missed_checkout`.

- [ ] **Step 1: Failing tests:** unit — `checkOutIso` (same day, next day, equal time = next day, invalid text → null, UTC offset); manual-punch library no longer has check-out wording; behaviour — a review row of a check-in with `missed_checkout` shows «إضافة الانصراف» and no «قبول» change, the dialog asks only a time and a note, sends `add_check_out` with the ISO time, shows the toast, reloads the card and the table; the dialog rejects an empty time and a future time before sending; a refusal text from the server is shown and the dialog stays open; the attendance tab dialog has no kind select and always sends `check_in`.
- [ ] **Step 2: Run `npm test` and `behavior.mjs`, expect those FAIL.**
- [ ] **Step 3: Implement** `openAddCheckOut` as the twin of `openAddCheckIn` (same markup, wording «سجّل حضوره يوم … الساعة … ولم يسجّل انصرافه»), the helper, and the dialog simplification; the check-in toast says «أضف الانصراف من «حركات تحتاج مراجعة»».
- [ ] **Step 4: Run all panel suites, expect PASS; mutation-check** (button hidden for non-missed rows, wrong action name, next-day rule removed, reload hooks removed).

### Task 7: Hand-off

**Files:** `CHANGELOG.md`, `docs/API_CONTRACT.md` (new §9), `docs/PHASE21_RUN_LOCALLY.md`, panel `README.md`, `waqti_admin_12_18.zip`

- [ ] **Step 1:** write the docs from the real numbers (database total, panel, app), the fingerprint query for the migration, the rollback note, the rulings R1–R4.
- [ ] **Step 2:** version bump 12.17 → 12.18 (`package.json`, `index.html` twice; this zip also carries the phase 20 panel changes, so it supersedes `waqti_admin_12_17.zip`), `python3 scripts/pack.py /home/claude/out`, run `behavior.mjs` on the unzipped copy.
- [ ] **Step 3:** whole-branch check: `bash local/test-db.sh` (all green), app tests, panel tests; read-only production check that the functions to be replaced match the repository (fingerprints), as done for phases 19 and 20.
- [ ] **Step 4:** commit locally; send the zip; report; **ask «نعم» for production and «ارفع» for the push**.
