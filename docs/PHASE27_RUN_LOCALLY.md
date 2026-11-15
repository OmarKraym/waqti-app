# Phase 27 — editing the time of one movement («تعديل» in the attendance table): run it locally, and how to apply it later

One migration and the admin panel **12.26.0**. **Nothing of phase 27 is applied to production, deployed or pushed.** Branch: `feature/punch-mode-company-roles` (local commits only; the panel folder is not a git repo, so the panel is delivered as a zip).

| | Migration (+ rollback `…_ROLLBACK.sql`) | Needs before it | Panel | App |
|---|---|---|---|---|
| **27 — edit the time of a movement** | `supabase/migrations/20261115110000_phase27_admin_edit_punch.sql` | phase 20 (`admin_add_punch`); the file stops with a clear message if `require_company_admin`, `audit_write`, `admin_add_punch` or `attendance_sessions` is missing | a «تعديل» button on every row of the attendance table (owner only); dialog «تعديل الحركة» | none |

Request from Omar (2026-11-15, screenshot of the attendance tab): «عدل الزر … الى إضافة حركة، ومن النافذة التي تظهر يتم تحديد اما حضور او انصراف، وقم بإضافة زر تعديل أمام كل حركة».
- **Part 1, «إضافة حركة»:** panel only. The button `#f-add` says «إضافة حركة»; its dialog has a «نوع الحركة» list (حضور / انصراف) that changes the hint and the refusal texts. It calls the same `admin_add_punch` as before (phase 20 already accepts both kinds), so **part 1 needs no database change**.
- **Part 2, «تعديل»:** the migration above, plus the button and the dialog.

## What `admin_edit_punch(p_event_id, p_time, p_reason)` does
Returns `{event_id, event_type, employee_id, previous_time, occurred_at}`. Checks, in this order (the first failure raises and **nothing is written**):
1. owner only (`require_company_admin()`; a phase 26 limited level is refused with `forbidden` because the allow-list has no row for this function);
2. `reason_required`: a reason of 3 to 500 letters;
3. `invalid_time`: the new time is not null, not in the future, not more than 62 days back;
4. `not_found`: the event is not in the caller's company (the message is the same for another company's event, so it does not reveal that it exists);
5. the employee row is locked first, then the event (the same order as `record_punch`, so a punch and an edit of the same employee never deadlock);
6. `no_change`: the new time equals the one it has;
7. `day_changed`: the new time is on another day of the company clock;
8. `invalid_time`: the new time is not **strictly between** the employee's previous and next movement;
9. `invalid_time`: if the session has both movements, the pair stays longer than zero and at most 24 hours (the same rule as a check-out added by `admin_add_punch`).

Then it changes **only `occurred_at`**, and writes on the event: `metadata.edited = true`, `metadata.original_occurred_at` (the time before the *first* edit, kept by later edits), `metadata.edits[]` (at, by, from, to, reason); touches `attendance_sessions.updated_at`; and writes the audit row `attendance.edit_time` (employee, kind, from, to, reason). Lateness, early leave, the deduction (phase 19) and overtime are computed from `occurred_at` each time they are read, so they follow the new time without any recompute (tested: a late check-in of 20 minutes read through `admin_list_attendance` becomes 0 after the edit).

**Not in this phase, on purpose:** changing the kind (check-in ↔ check-out), changing the day, deleting a movement. Omar asked for «تعديل» only; each of those changes how sessions pair up, the stored `work_date`, or the leave days a punch cancels (phases 15 and 22), so they are separate decisions.

## 1. Run the database test (local only)
```bash
cd supabase
PGDATABASE=postgres TESTS=tests/phase27_admin_edit_punch_tests.sql bash local/test-db.sh    # only phase 27 (50 assertions)
PGDATABASE=postgres bash local/test-db.sh                                                    # every file, each on a fresh database
```
Same setup as phases 24 to 26 (Postgres 16 + PostGIS, libfaketime). **Start the server with `PGHOST` and `PGPORT` in its own environment** (not only in the shell that runs the tests): the phase 21 test connects to the same server through `dblink`, and without them it looks for the default socket, fails, and its part 4 (19 assertions) does not run. This happened once while proving phase 27 (a first full run gave 1842 passed / 2 failed; the same on a database without phase 27; fixed by restarting the server with the variables; rerun 1861 / 1). The file covers: privileges (anon, an employee, another company, a phase 26 hr_admin are refused); each refusal; a good edit (the event, the session, the audit row, live lateness); a second edit keeps the first original; a check-out edit; the neighbours rule with two sessions on one day; the 24-hour rule across midnight; a waiting check-in keeps its review flag; the audit count (refused calls write nothing).
**Red first:** the file was run before the function existed and failed on the missing function; then 50 / 50. **Mutation check:** 8 deliberate breaks of the function — no same-day check, no previous-neighbour check, no next-neighbour check, no 24-hour rule, no audit row, the first original overwritten by a later edit, the reason optional, no company scope — were each caught by at least one assertion (8 / 8).

## 2. Other tests (last run 2026-11-15)
| What | Command | Result |
|---|---|---|
| Database, phase 27 | §1 | 50 passed, 0 failed |
| Database, whole suite | §1 | **38 files, 1861 passed, 1 failed** — the one failure is `phase15_leave_conflict_tests.sql` (clock, see below); the 37 older files give exactly the results they gave before (1811 + 50 = 1861) |
| Database, rollback proof | build all migrations, apply the phase 27 rollback, compare with a database built without 27 | 857 lines identical (§4) |
| Admin panel, unit | `npm test` (panel folder) | 185 / 185 (179 + 6 for the edit dialog's rules); also 185 / 185 from the extracted zip |
| Admin panel, behaviour (fake client, Playwright) | `node tests/ui/behavior.mjs .` | 649 passed, 0 failed (609 + 40 new); also 649 / 0 from the extracted zip |
| Admin panel, layout, every screen | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir> [--scheme dark]` and `--scenario levels` | v12 light 366 screens, dark 366 (18 new: the actions column, the dialog and its message, at 6 widths); levels light 66, dark 66 — 0 with problems, 0 issues, 0 script errors in all four |
| Admin panel, CSS | `npx stylelint "styles/**/*.css"` | clean (no CSS was added) |
| Mutation check of the panel | two copies of the panel: gating check removed; table reload after saving removed | both caught: the first fails 3 gating checks (hr_admin, supervisor and viewer saw the button); the second times out waiting for the row to show the new time |
| App | not touched by this phase | — |

## 3. How to apply it later (needs Omar's fresh «نعم»)
**Order: migration → panel.** The panel is also safe *before* the migration: the button is drawn for the owner, and on a database without the function the dialog says «هذه الميزة غير متاحة بعد». Part 1 («إضافة حركة») works on today's database. Panel = «انشر» (a separate step); a push = «ارفع».
1. Apply the migration with `apply_migration` (one call, the exact file text; check with grep that the file has no backslash). One transaction: if the guard fails, nothing is kept.
2. Compare with the local value (`md5(prosrc)` of the function, read from the local database after all migrations):

| Function | `md5(prosrc)` | secdef / volatility | settings / grants |
|---|---|---|---|
| `public.admin_edit_punch(uuid, timestamptz, text)` | `94750b853f33e9c54c3bdc2e43350142` | yes / volatile | `search_path=public`; execute for `postgres`, `authenticated`, `service_role`; **not** for `anon` or `public` |

3. Smoke test after applying (read-only): `select has_function_privilege('authenticated', 'public.admin_edit_punch(uuid, timestamptz, text)', 'execute')` must be true and the same with `'anon'` false. Nothing changes for anyone until an owner presses «تعديل» and saves.

## 4. Rollback
`…_phase27_admin_edit_punch_ROLLBACK.sql` (`psql -1`): it only drops `admin_edit_punch`.
- **Edits already made stay.** The events keep their new times; the original time and the reasons stay in `metadata` and in the audit log (`attendance.edit_time`). The rollback does not put old times back (that would be a second, silent edit). The panel's «تعديل» then answers «غير متاحة بعد».
- **Proof (2026-11-15):** a database built from every migration **except** 27 and a database built from **all** of them followed by the rollback were compared: 857 lines of functions (`md5(prosrc)`, security, volatility, settings, grants), columns, constraints and tables — **identical**. As a check that the comparison can see the function, the same comparison between "without 27" and "with 27" differs in exactly one line (`fn admin_edit_punch(uuid,timestamp with time zone,text) …`).

## 5. Rulings and known limits (read before saying «نعم»)
1. **Time only, same day, between the neighbours.** This is the smallest edit that answers «تعديل أمام كل حركة» without touching how days and sessions are built. If Omar wants to change the kind, the day, or to delete, say so: each is its own phase.
2. **Owner only.** Phase 26 is default-deny, so hr_admin, supervisor and viewer neither see the button nor can call the function. To let HR use it later, insert one row in `private.admin_role_rpcs` (role `hr_admin`, rpc `admin_edit_punch`); the panel then shows the button for HR by itself.
3. **The table shows only the new time.** There is no «معدَّل» mark in the movements table, and everything else that reads `occurred_at` (the Excel reports, the employee's own history) shows the new time too. The original time is in the audit log and in `metadata.original_occurred_at`. If a mark in the table is wanted, it is a small panel change (the metadata is not returned by `admin_list_attendance` today, so it would also be a database change).
4. **An edit is a correction of the record, not a new punch.** It does not run the geofence or the device checks again, and it does not touch `created_at` (the moment the server first saved the punch stays).
5. **The edit window is the same 62 days as `admin_add_punch`.** A movement older than that shows the button, and the dialog says why it cannot be edited.
6. **Not tested with two real concurrent sessions** (the lock order is the same as `record_punch`, and the rules are tested).
7. Part 1 of the request («إضافة حركة»): the review window keeps its own «إضافة الانصراف» (it also clears the review row). That was left as it was. The earlier ruling of phase 20c («add check-in only» in the manual dialog) is lifted by this request.
