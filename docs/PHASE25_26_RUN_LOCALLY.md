# Phases 25 and 26 — automatic punch button, and admin levels inside a company: run it locally, and how to apply it later

Two migrations, the admin panel **12.25.0** and the employee app (punch screen). **Nothing of phases 25 or 26 is applied to production, deployed or pushed.** Branch: `feature/punch-mode-company-roles` (local commits only).

| | Migration (+ rollback `…_ROLLBACK.sql`) | Needs before it | Panel | App |
|---|---|---|---|---|
| **25 — automatic punch button** | `supabase/migrations/20261115090000_phase25_auto_punch_mode.sql` | phases 8a and 22 | card «الزر التلقائي» in Settings ← البصمة (hidden on an older database) | punch screen reads `punch_mode`; late-arrival question after a check-in removed; error `mode_mismatch` |
| **26 — admin levels** | `supabase/migrations/20261115100000_phase26_admin_roles.sql` | phases 16 and 21 | levels in Settings ← المدراء; every screen hides what the level cannot do | none |

Request from Omar (2026-11-14, «fix it and work» 2026-11-15): the app only checks and saves the punch (security, geofence, no lateness, no overtime); a company can have people with limited admin levels; the punch button follows the employee's own shift (flips at the middle of the shift, back at 12:00 AM); **nothing existing is changed** — requests stay as they are.

## What phase 25 does
- `companies.auto_punch_mode` (default **off**). With the switch off, every added line of the migration is guarded: nothing changes.
- On: `expected = check_out` only when the employee has an open check-in **today** (company time) and now ≥ the flip time; otherwise `check_in`. Flip time = start + (end − start) / 2 of **his own** shift, or the exit time of an approved early-leave permission when that is earlier. The day resets at 00:00 company time. A punch of the other kind is refused with `mode_mismatch`.
- A check-in left open on a previous day is marked `missed_checkout` and flagged for review (nothing is invented: no check-out time); it does not block today's check-in.
- New: `admin_get_auto_punch_mode()` → `{enabled}`, `admin_set_auto_punch_mode(boolean)`, `admin_punch_mode_preview(employee, at)` (what the button would be, and why), `private.punch_mode`, `private.expected_punch_type`, `private.flag_stale_open_session`. Changed: `private.record_punch` (3 guarded additions), `public.employee_attendance_state` (new key `punch_mode`).

## What phase 26 does
- The owner (`company_members.role = 'company_admin'`) is unchanged. Three limited levels in the same column: **hr_admin**, **supervisor**, **viewer**.
- **Default deny.** `public.require_company_admin()` is the single gate of every `admin_*` function. A limited level passes only if the **outermost** `admin_*` function on the call stack is listed for his level in `private.admin_role_rpcs` (23 viewer rows, 32 supervisor, 46 hr_admin — already cumulative). A new `admin_*` function is owner-only until a row is inserted for it. No `admin_*` frame on the stack (direct call, trigger, plain SQL) = closed.
- `admin_company_id()` stays owner-only, so a limited level gets no direct table access.
- A limited level cannot touch an account that holds any admin level (`private.assert_not_admin_target`): one extra line at the start of 12 employee-targeting functions (see §3). For an owner it returns at once.
- Admin levels sign in with the password only (like the owner); deleting an account that holds a level is refused until the level is taken away.
- New: `admin_list_admin_roles()`, `admin_set_admin_role(uuid, text)` (owner only, audited, one change at a time per company, never your own, never the last working owner). `my_admin_context()` gets `admin_role`, `is_panel_user`, `permissions` (null = everything).

| Level | Can | Cannot |
|---|---|---|
| **company_admin** (owner) | everything | — |
| **hr_admin** | everything a supervisor does + employee profile (**salaries included**), schedule, geofence, grace, kind days, leave year, manager, devices, manual punch, update employee | settings, company-wide rules (leave days, holidays, permission types, custom kinds), add / delete employees, reset passwords (edge functions), set levels |
| **supervisor** | everything a viewer sees + the review queue, decide requests and leave days, resolve reviews and leave conflicts, dismiss a missing check-in, read grace / kind days / leave years | change employee data, see salaries, cancel a company leave day |
| **viewer** | read only: employees (no salary), attendance, missing check-ins, requests, overtime, leave days, holidays, and the settings screens (company, punch, grace, holidays, leave policy, overtime, approval paths) | change anything, see salaries, see the review queue |

## 1. Run the database tests (local only)
```bash
cd supabase
PGDATABASE=postgres bash local/test-db.sh                                                  # every file, each on a fresh database
PGDATABASE=postgres TESTS=tests/phase25_auto_punch_mode_tests.sql bash local/test-db.sh    # only phase 25 (50 assertions)
PGDATABASE=postgres TESTS=tests/phase26_admin_roles_tests.sql bash local/test-db.sh        # only phase 26 (161 assertions)
```
Same setup as phase 24 (Postgres 16 + PostGIS, libfaketime). Tests of phases 14, 15 and 23 depend on the time of day (known, not caused by 25 or 26): on the final tree the full suite gave **37 files, 1811 passed, 1 failed** — the one failure is `phase15_leave_conflict_tests.sql`, which stops before it counts anything when the local clock is before noon, and it does exactly the same on a database without phases 25 and 26.

## 2. Other tests (last run 2026-11-15)
| What | Command | Result |
|---|---|---|
| Database, phase 25 + 26 | §1 | 50 + 161 = 211 passed, 0 failed |
| Database, whole suite | §1 | 1811 passed, 1 failed (phase 15, clock, see §1) |
| Database, rolled back (both rollbacks applied, then every older test file) | build all migrations, rollback 26, rollback 25, run the other test files | the 35 older files: **1600 passed, 1 failed** (phase 15, clock) — the same per-file results as the same 35 files on a normal database (`diff` empty) |
| Admin panel, unit | `npm test` (panel folder) | 176 / 176 |
| Admin panel, behaviour (fake client, Playwright) | `node tests/ui/behavior.mjs .` | 600 passed, 0 failed |
| Admin panel, layout, every screen | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir> [--scheme dark]` and `--scenario levels` | v12 light 348 screens, dark 348; levels light 66, dark 66 — 0 with problems, 0 issues, 0 script errors in all four |
| Admin panel, CSS | `npx stylelint "styles/**/*.css"` | clean |
| App, unit | `npm test` | 435 / 435 (29 files) |
| App, types, CSS and build | `npm run typecheck`, `npm run lint:css`, `npm run build` | clean; 36 precache entries |
| Mutation check of the panel gating | a copy of the panel with a gating check removed | the behaviour suite failed on it (the gating tests do catch a missing check) |

## 3. How to apply it later (needs Omar's fresh «نعم» for each migration)
**Order: phase 25 migration → phase 26 migration → panel → app.** Panel and app each need «انشر» (a separate step). Every new screen and call degrades silently on an older database (the card or pane is not drawn), so the order of panel and database does not break anyone.

1. Apply each migration with `apply_migration` (one call, the exact file text; check with grep that the file has no backslash). Both run as one transaction: a failed guard or a failed patch keeps **nothing**.
2. Phase 26 patches 12 existing functions by reading their text from the database and inserting one line after the first line that is only `begin` (`CREATE OR REPLACE` keeps grants). The run stops without keeping anything if a function does not have exactly one such line. **Found on 2026-11-16 (first production attempt, kept nothing):** `admin_set_leave_year` in production has Windows line ends (CRLF) in its body — so does `admin_cancel_leave_day`, `admin_decide_request`, `admin_get_leave_policy`, `admin_get_leave_years`, `admin_list_leave_days`, `admin_list_requests`, `admin_save_leave_day`, `admin_set_leave_policy` — and the first version of the file looked only for `LF begin LF`. The patch now follows the line-end style of each function (CRLF in, CRLF line added; LF as before) and the rollback removes the line with its own line end. Proven locally: a database where `admin_set_leave_year` is converted to CRLF takes phases 26–28 (tests 161 / 50 / 139 pass), and phase 26 then its rollback gives back the byte-identical earlier text of all 80 functions compared (the 77 `admin_*` functions of that local build, `my_admin_context`, `require_company_admin` and `service_login_context`). The phase 26 file has two lines with a backslash (line 143, the gate's regexp, and line 308, the line-end choice `E'\r\n'` / `E'\n'`), so send it exactly as it is (18,765 bytes); phase 28 has none. Because the text comes from production, **do not compare these 12 by `md5`** (line endings may differ from local); compare that the body contains `perform private.assert_not_admin_target(p_employee_id);` exactly once.
3. Compare the other functions with local text (`md5(prosrc)`, security definer, volatility — the local values below were read from the local test database after all migrations):

| Function | `md5(prosrc)` | secdef / volatility |
|---|---|---|
| `private.expected_punch_type(uuid,timestamptz)` | `9e3eac49702ac9c18ca47c5053abb5cb` | yes / stable |
| `private.flag_stale_open_session(uuid,timestamptz)` | `70e3ec5eb702c1d6cfd616877fe43355` | yes / volatile |
| `private.punch_mode(uuid,timestamptz)` | `9fb4bd9507516afed2f546dfa52c8682` | yes / stable |
| `private.record_punch(…13 arguments)` | `70196581671cf126821ddbfd0784ea78` | yes / volatile |
| `public.admin_get_auto_punch_mode()` | `c8675e35767ccb6ece74c6d59c68f362` | yes / stable |
| `public.admin_punch_mode_preview(uuid,timestamptz)` | `39f20352e502b318245054cebbc26b46` | yes / stable |
| `public.admin_set_auto_punch_mode(boolean)` | `6abdb4918352b7cf674604aabc944319` | yes / volatile |
| `public.employee_attendance_state()` | `0c46527c99ad58ff1283a8c98cf0a04b` | yes / volatile |
| `private.assert_not_admin_target(uuid)` | `695e4b4cecac52c590d2ee62d8f7bf85` | yes / stable |
| `private.limited_admin()` | `1c52cdc736a21965eb20eb96f7e5b8c2` | yes / stable |
| `public.admin_list_admin_roles()` | `c305d7d4c9942d150fa62a04cb177a53` | yes / volatile |
| `public.admin_set_admin_role(uuid,text)` | `44b0b4dcafd3cbf5e3997b84c0e6b7fe` | yes / volatile |
| `public.my_admin_context()` | `7d28b12e8613aa1aa2b3fe14a336e1ff` | yes / stable |
| `public.require_company_admin()` | `fd010c9918861feb55d1011c84114996` | yes / stable |

   Group fingerprint of the eight phase 25 functions (`md5(string_agg(md5(prosrc), '' order by proname))`): `615d2fac030b9e1f46de5a4fe77ec303`. After phase 26: `select role, count(*) from private.admin_role_rpcs group by 1` must give hr_admin 46, supervisor 32, viewer 23.
   `service_login_context(text)` and `admin_delete_employee(uuid,text)` are also patched by phase 26 in place (one replaced line each); like the 12, compare by content, not by `md5`.
4. Smoke test after applying (read-only, as the owner): `select public.my_admin_context()` must contain `admin_role: "company_admin"`; `select public.admin_get_auto_punch_mode()` must give `{"enabled": false}`. The punch button does not change for anyone until the owner turns the card on.

## 4. Rollback
`…_phase26_admin_roles_ROLLBACK.sql` first, then `…_phase25_auto_punch_mode_ROLLBACK.sql`; each in one transaction (`psql -1`).
- **26:** every account that holds a limited level becomes an ordinary employee again (it loses the panel); owners are not touched; the 12 extra lines and the two in-place patches are taken out; the allow-list table and the new functions are dropped; the role constraint goes back to `company_admin` / `employee`.
- **25:** `record_punch` and `employee_attendance_state` go back to the text they had before phase 25; the three new functions, the three private helpers and the column `companies.auto_punch_mode` are dropped (the switch setting is lost).
- **Proof (2026-11-15):** a database built from every migration **except** 25 and 26 and a database built from **all** of them followed by the two rollbacks were compared: 842 lines of functions (`md5(prosrc)`, security, volatility, settings, grants), columns, constraints and tables — **identical**. Then every older test file ran on the rolled-back database (see §2).
- **Found by that proof, and fixed before anything was applied:** the first version of the phase 25 rollback restored the two functions with text that still read `companies.auto_punch_mode` and then dropped the column, so every punch would have failed after a rollback. Commit `fix(db): phase 25 rollback restores the real earlier function text`.

## 5. Rulings and known limits (read before saying «نعم»)
1. **The panel trusts the database, not the sign-in token.** A promoted admin's token still says `employee`; the panel asks `my_admin_context()` at sign-in. The level is read once per sign-in: a level changed mid-session shows after the next sign-in (the database refuses wrong calls at once).
2. **hr_admin reads salaries**, including the owner's profile, and edits employee profiles. If that is too much, take `admin_get_employee_profile` and `admin_save_employee_profile` out of the hr_admin rows (one `delete`, no code change) and the profile screen will hide itself.
3. **hr_admin cannot add employees or reset passwords**: those are edge functions (`create-employee`, `reset-employee-password`) that accept the owner only. Changing that needs an edge-function change and «انشر».
4. **A supervisor can add a missing check-in or check-out through the review queue** (`admin_resolve_review` is his), but not through the manual-punch button (`admin_add_punch` is hr_admin's). The allow-list is per function, not per action.
5. **A supervisor can decide a request made by an admin or the owner.** The guard on admin accounts covers employee-targeting writes only.
6. Limited levels get no HR-step approvals and no notifications of that step (the «hr» approver stays with owners).
7. For viewer and supervisor, the detailed attendance report loses the schedule columns (they need `admin_get_employee_profile`).
8. Concurrency: `admin_set_admin_role` takes a per-company lock; it was tested for the rules, **not** with two real concurrent sessions.
9. Phase 25: an approved early-leave permission moves the flip time earlier (so nobody waits for the middle of a shift the company already let him leave). The late-offer code on the app side (`lateOffer` and its API call) is no longer used by the punch screen and was left in place, so nothing existing was deleted.
10. Phase 25 changes one visible thing in the app even with the switch off: after a check-in the app no longer asks about lateness (the prompt asked for a punch-only app). Permissions stay in the requests tab.
