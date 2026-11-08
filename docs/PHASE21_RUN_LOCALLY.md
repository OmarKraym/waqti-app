# Phase 21 (and 20c) — delete a work place / an employee, the forgotten check-out from the review window, the «install» line on the login screen: run it locally, and how to apply it later

This round = two migrations (**20c** `admin_resolve_review` gets the action `add_check_out`; **21** soft delete of work places and employees), admin panel **12.18.0**
(it also carries the 12.17 panel, so `waqti_admin_12_18.zip` supersedes `waqti_admin_12_17.zip`) and app changes (the «install the app» line on the login screen; 20b's «أضافه المدير» mark from phase 20).
**The three migrations (20b, 20c, 21) were applied to production on 2026-11-08 after Omar's «طبق أي شيء جاهز» (§3, "What was done"). The panel 12.18 is not installed and the app is not deployed.** Every test below ran on a throwaway local database or the fake server.

## 1. Run the database tests (local only, never production)

Same as phase 20: a local Postgres 16 with PostGIS where you may create databases, clock fixed on Saturday 2026-10-31 10:00 (libfaketime).

```bash
cd supabase
bash local/test-db.sh                                                              # every file in tests/, each on a fresh database
TESTS=tests/phase21_workplaces_delete_employee_tests.sql bash local/test-db.sh     # only phase 21
TESTS=tests/phase20c_review_add_check_out_tests.sql bash local/test-db.sh          # only phase 20c
```

Each migration has a `_ROLLBACK.sql`. **How the phase 21 rollback was proven:** apply everything, run the rollback, run the older tests on that database (phase 16, 16c, 8b, security fixes: 170 / 170),
compare the four replaced functions with their pre-21 text (identical apart from white space), check that both delete functions and the trigger are gone, apply 21 again and compare the fingerprint (§3: identical).
The rollback **keeps** the `deleted_at` columns and the check constraint on purpose (the record of what was deleted); the removal of them is a manual step written at the top of the rollback file.

## 2. Run the other tests

| What | Command (folder) | Result of the last run (2026-11-08) |
|---|---|---|
| Database, all files | `bash local/test-db.sh` (`supabase/`) | **TOTAL passed=1313 failed=0** (31 files; phase 20: 69, phase 20c: 48, phase 21: 147) |
| Admin panel, unit | `npm test` (panel folder) | 78 / 78 |
| Admin panel, behaviour (Playwright, fake server) | `node tests/ui/behavior.mjs .` | 381 passed, 0 failed (also on the unzipped `waqti_admin_12_18.zip`) |
| Admin panel, layout | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir>` (about 4 minutes) | 300 screens (on the unzipped zip), 0 with problems, 0 script errors |
| App, unit | `npx vitest run` (repo root) | 376 / 376 (25 files; 24 new: 19 for the install store, 5 guards for where the install line may live) |
| App, types | `npx tsc -b` | clean |
| App, production build | `npm run build` | builds |
| Panel zip | `python3 scripts/pack.py <dir>`, then `behavior.mjs` on the unzipped copy | `waqti_admin_12_18.zip` (90 files, 238 imports versioned `?v=12.18`) |
| App in the browser, fake server | `VITE_MOCK=1 npx vite --port 5179`, open `/?install=1` | the line shows under the login form (Chrome: «تثبيت»; iPhone: «كيف؟» opens the Share → Add to Home Screen sentence); gone after the close button and after a reload; none when opened as the installed app; none inside Home. Checked at 360 and 320 px. |

What the database tests cover (phase 21, four parts): **1** the schema and the work places: the new columns, the name index, the exact column lists of the changed functions, who may execute (authenticated yes, anon no), a place of another company (`not_found`), the refusals,
moving active employees (they get the new place's geofence), inactive ones staying on the old place, the same name added again, the guard trigger, the counts of the lists, the audit rows (none for refused calls);
**2** deleting an employee: every refusal, in order; **3** the success path: the row stays (inactive, same number and name), the phone binding and his push subscriptions go and those of others stay, his flagged check-in is still in the review queue, his history is untouched, a former admin can be deleted, the typed name matches across Unicode forms;
**4** six races (dblink, two or three sessions): a move into a place against the delete of that place, two deletes of one place, a delete against an admin promotion of the same employee, and so on.

Mutation checks (change the code on purpose, the tests must fail, then restore): migration 21: 52, all killed after four first-round gaps were closed;
20c: 24 killed (plus one equivalent mutant: dropping the `event_type` check changes nothing, the session lookup by `check_in_event_id` is the real gate); panel: 51 for the two delete dialogs, the row menu and the form hint, 25 for the check-out window, 6 for the form's place choice, all killed
(the first run of the delete dialogs found a real bug: Enter pressed twice sent two requests; a surviving mutant found another: after a stale refusal the same dialog's later success left the old list on screen — both fixed, test first);
app: the three placement guards were each mutated and killed.

## 3. Applying on production (ONLY after Omar says «نعم», one part at a time)

### What was done (2026-11-08)

Omar answered the question «أي جزء تسمح لي بتطبيقه على الإنتاج الآن؟» with «طبق أي شيء جاهز»; the three migrations were applied one at a time with the Supabase tool (`apply_migration`), each checked against the local fingerprint before the next.
The panel zip is installed by the administrator and the app deploy needs its own «نعم» (§3 step 5): **neither was done**.

| Order | Migration name on production | Check after applying |
|---|---|---|
| 1 | `phase20b_employee_state_admin_flag` | `employee_attendance_state`: 1 row, `755f640ddfdfa54e26719f228211da48` (was `51e02778…`); anon no, authenticated yes |
| 2 | `phase20c_review_add_check_out` | `admin_resolve_review`: 1 row, `80c2d3d554b10f2ffd90a5a6dd6ae652` (was `9689e17d…`); anon no, authenticated yes |
| 3 | `phase21_workplaces_delete_employee` | the four replaced functions: `fc001e0c168a118a6b0b8ade818b262a` (was `42dc4dc2…`); `deleted_at` on both tables; the guard trigger; grants f/f/t/t; the name index covers live places only; **nothing deleted** (7 places, 68 employees, 0 deleted of each, the same counts as before) |
| 4 | `phase21_admin_delete_employee_nbsp_escape` | see the note below: the three new functions `29f80512d7d5c396eae8ece6527f60a8` |

**Note on step 4 (a transcription slip, found by the fingerprint check).** The migration text is sent to the tool as a parameter, and the escape `\u00a0` inside `admin_delete_employee` arrived as a raw non-breaking space (the function text was 10 characters shorter: `bc4e6122…` instead of `0269ef85…`).
Behaviour was the same (the regex matches the same character either way), but the text no longer equalled the repository file, so the function was written again with the escape rebuilt from `chr(92) || 'u00a0'`; its text is now identical to the file (`0269ef85e536741f0637c485546f823d`, length 2628).
Production's migration history therefore has this fourth entry, which has no file in the repository (it carries the same function as phase 21). **Lesson for the next migration: compare the fingerprint of every new function, not only the aggregate, and avoid backslash escapes in text sent through the tool.**
No backup was taken: Supabase's backup button is not reachable from the tool; the three migrations are one transaction each, add no data and have rollbacks that delete nothing (the migration only adds two nullable columns and rebuilds the place-name index on 7 rows).
No test call was made on production (it would write data); the suggested real-use test at the end of this section is the first real use.

State read **before applying, on 2026-11-08 with SELECT only**:

| Function / object | Production now | = |
|---|---|---|
| the four functions phase 21 replaces (`admin_list_work_locations`, `admin_list_employees`, `admin_add_work_location`, `platform_list_companies`) | 4 rows, `42dc4dc271627d75cf17c651c5bd6e73` | exactly the text the ROLLBACK file restores |
| `admin_delete_work_location`, `admin_delete_employee`, `private.guard_deleted_location` | 0 rows | not there yet |
| `deleted_at` on `work_locations` / `employees` | 0 columns | not there yet |
| `admin_resolve_review` | 1 row, `9689e17deb92b70625e6249723c4cb0d` | the phase 14 version (what 20c replaces) |
| `employee_attendance_state` | 1 row, `51e02778b74d5a6f53a796c59e739917` | the phase 14 version (what 20b replaces) |
| `admin_add_punch` | 1 row, `71b512a9be0cb099bdff7fecbae66620` | phase 20, applied on 2026-11-08 |

1. **Back up first.** Supabase → Database → Backups: take a manual backup (or confirm today's daily one exists). Note the time.
2. Apply **one at a time**, running its check before the next. Plain SQL, a guard block that stops with a clear message if a previous phase is missing, one transaction each. The three are independent of each other.
   - **20b** `20261108140000_phase20b_employee_state_admin_flag.sql` (from phase 20; still waiting)
   - **20c** `20261108150000_phase20c_review_add_check_out.sql`
   - **21**  `20261109100000_phase21_workplaces_delete_employee.sql` (the only one that adds columns; it rebuilds the work-place name index to cover live places only: with a few places it is instant)
3. **Check each one against the local fingerprint** (`md5(string_agg(md5(prosrc), '' order by proname))`):

```sql
-- 20b   expected: 1 row, 755f640ddfdfa54e26719f228211da48
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'employee_attendance_state';

-- 20c   expected: 1 row, 80c2d3d554b10f2ffd90a5a6dd6ae652   (before: 9689e17deb92b70625e6249723c4cb0d)
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_resolve_review';

-- 21    expected: 4 rows fc001e0c168a118a6b0b8ade818b262a   (before: 4 rows 42dc4dc271627d75cf17c651c5bd6e73)
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc
 where pronamespace = 'public'::regnamespace
   and proname in ('admin_list_work_locations','admin_list_employees','admin_add_work_location','platform_list_companies');
-- 21    expected: 3 rows 29f80512d7d5c396eae8ece6527f60a8
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc
 where (pronamespace = 'public'::regnamespace and proname in ('admin_delete_work_location','admin_delete_employee'))
    or (pronamespace = 'private'::regnamespace and proname = 'guard_deleted_location');
-- 21    expected: 2
select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'deleted_at' and table_name in ('work_locations','employees');
-- 21    expected: f, f, t, t
select has_function_privilege('anon', 'public.admin_delete_work_location(uuid, uuid)', 'execute'), has_function_privilege('anon', 'public.admin_delete_employee(uuid, text)', 'execute'),
       has_function_privilege('authenticated', 'public.admin_delete_work_location(uuid, uuid)', 'execute'), has_function_privilege('authenticated', 'public.admin_delete_employee(uuid, text)', 'execute');
```

4. After 21 the employees list and the places list look the same to everyone (nobody is deleted yet): open the panel (the old one still works) and the employee app, both must load as before.
5. The panel zip `waqti_admin_12_18.zip` is installed by the administrator (outside this repository). The app is deployed separately. Either may go first: a panel newer than the database says «ميزة الحذف غير متاحة بعد» in the dialog and shows the old window for the check-out until 20c is applied; an app without the new database loses nothing (the install line needs no database).
6. If something is wrong: the `_ROLLBACK.sql` of the migration, newest first (21, then 20c, then 20b). They never delete attendance data. Rolling back 21 keeps `deleted_at`: a deleted place shows again in the lists with «(محذوف …)» added to its name, a deleted employee comes back in the lists as **inactive**; employees who were moved out of a deleted place stay where they were moved.

A real use test after applying (suggested, with a test place and a test employee): add a test place → delete it (no employees: it goes at once); create a test employee, delete him by typing his name → he leaves the lists, his number cannot be used again, the audit log has `employee.delete`;
give an employee a missed check-out (or use the review card) → «إضافة الانصراف» closes the session and the card entry goes (`attendance.review_add_check_out`).
