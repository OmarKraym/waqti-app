# Phase 19 — run it locally, and how to apply it later

Phase 19 = three migrations (19a late rule, 19b deduction policies, 19c late status + limit guard), admin panel 12.16.0 and an app change.
**Nothing was applied to production, deployed or pushed.** Everything below ran on a throwaway local database.

## 1. Run the database tests (local only, never production)

Needs a local Postgres 16 with PostGIS where you may create databases (`PGHOST/PGPORT/PGUSER`).

```bash
cd supabase
bash local/test-db.sh                                       # every file in tests/, each on a fresh database
TESTS="tests/phase19a_late_rule_tests.sql tests/phase19b_deduction_policies_tests.sql tests/phase19c_late_status_tests.sql" bash local/test-db.sh
bash local/concurrency-limit.sh                             # two real sessions race for the last monthly justification
DROP_TRIGGER=1 bash local/concurrency-limit.sh              # the same with the 19c trigger removed: must FAIL (2 successes)
```

Some tests pick dates relative to today and assume a Saturday–Thursday week. The server that produced the numbers below ran with
the clock fixed (libfaketime, Saturday 2026-10-31 10:00); if a test fails only because of the weekday or the hour, do the same.

Each migration has a `_ROLLBACK.sql`. To try one locally: apply everything, run the rollback, run the older tests, apply the
migration again and compare the fingerprint (§3).

## 2. Run the other tests

| What | Command (folder) | Result of the last run |
|---|---|---|
| Database, all files | `bash local/test-db.sh` (`supabase/`) | **TOTAL passed=1049 failed=0** (28 files; the three phase 19 files: 40 + 134 + 83) |
| Concurrency | `bash local/concurrency-limit.sh` | function path 1 success + 1 `permission_limit`; plain INSERT 1 + 1; with `DROP_TRIGGER=1` the plain INSERT gives 2 successes (FAIL, as intended) |
| Admin panel, unit | `npm test` (panel folder) | 46 / 46 |
| Admin panel, behaviour (Playwright, fake server) | `node tests/ui/behavior.mjs .` | 223 passed, 0 failed |
| Admin panel, layout | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir>` (about 4 minutes) | 264 screens, 0 with problems, 0 script errors |
| App, unit | `npx vitest run` (repo root) | 349 / 349 (23 files) |
| App, types | `npx tsc -b` | clean |
| App, production build | `npm run build` | builds (the usual chunk-size warning only) |
| App, in the browser with the fake server | `VITE_MOCK=1 npx vite --port 5179`, then open e.g. `http://localhost:5179/?clock=2026-11-03T06:39:00Z` | see below |

The fake server decides like the real one and takes flags: `clock=` (the fake server clock STARTS at that instant and then runs;
Tripoli is UTC+2, so `06:39:00Z` = 08:39 and a punch a few seconds later is 40 minutes late), `grace=15` (default), `rule=beyond_grace`,
`lateused=3` (this month's justifications already used; 3 = none left), `deduct=1` (a stand-in policy), `net=flaky`.
Scenarios checked at 360×740: late with balance → dialog «تقديم تبرير» and the form opens with the arrival time; no balance → one
dismissible line, no dialog; inside the grace → nothing; `beyond_grace` → the dialog shows the counted minutes; too long + policy → the line
shows the limit and the expected deduction; a Friday (day off) → nothing; the line is cleared by the next punch.

Mutation checks (change the code on purpose, the tests must fail, then restore): 10 on the DB 19c function, 8 on the panel library,
5 on the panel screens, 14 on the app library, 1 on the app screen — all were killed after the tests were tightened.

## 3. Applying on production (ONLY after Omar says «نعم», one part at a time)

Not done. When approved:

1. **Back up first.** Supabase → Database → Backups: take a manual backup (or confirm today's daily backup exists). Note the time.
2. Apply in this order, **one at a time**, running its check before the next. The migrations are plain SQL with a guard block that
   stops with a clear message if the previous phase is missing, and each runs in one transaction (all or nothing).
   - **19a** `20261108100000_phase19a_late_rule.sql`
   - **19b** `20261108110000_phase19b_deduction_policies.sql`
   - **19c** `20261108120000_phase19c_late_status.sql`
3. **Check each one against the local fingerprint.** Run the query on production and compare it with the value from the local database
   (the counts must match too; a different count means a leftover overload of an old function):

```sql
-- 19a   expected: 4 rows, e281a0f50b63be16fdbda93fcd71b14a
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc
where proname in ('punch_lateness','admin_get_grace_settings','admin_set_late_rule','chargeable_minutes');
select data_type, column_default from information_schema.columns where table_name='companies' and column_name='late_rule';  -- text, 'all_after_grace'

-- 19b   expected: 12 rows, 1f9826776104e4ac5ed5297436316f51
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc
where proname in ('json_int','deduction_params_clean','deduction_params_ok','deduction_calc','late_deduction','deduction_policy_json',
  'admin_list_deduction_policies','admin_save_deduction_policy','admin_delete_deduction_policy','admin_preview_deduction',
  'punch_deduction','admin_list_attendance');
select relrowsecurity from pg_class where oid = 'public.deduction_policies'::regclass;                                       -- t

-- 19c   expected: 2 rows, df7977f94d7ca14aecd77876020fc1b8
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc
where proname in ('employee_late_status','requests_limit_guard');
select count(*) from pg_trigger where tgname = 'requests_limit_guard' and not tgisinternal;                                 -- 1
select has_function_privilege('anon', 'public.employee_late_status(uuid)', 'execute');                                      -- f
select has_function_privilege('authenticated', 'public.employee_late_status(uuid)', 'execute');                            -- t
```

   The fingerprints cover the migration text only; if production's older phases differ from the repository the 19a/19b numbers
   (they include `punch_lateness` and `admin_list_attendance`) will differ too — stop and look before going on.
4. After 19a–19c: open the attendance list in the panel (it must load; first arrivals now show the deduction state only if a policy exists),
   then check nothing changed for the company: the late and early minutes of a few days must read as before (the default rule is
   `all_after_grace`).
5. The panel zip `waqti_admin_12_16.zip` is installed by the administrator (outside this repository). The app is deployed separately.
   Either may go first: an app or panel newer than the database degrades quietly (§ "Risks" in `CHANGELOG.md`).
6. If something is wrong: run the three rollback files in reverse order (19c, 19b, 19a). They do not touch attendance or request
   data. Rolling 19b back drops `deduction_policies` and its rows.

A company that wants the deduction needs a policy saved in الإعدادات ← الدوام ← «سياسة الخصم» (start date today or later); until then
`deduction_minutes` stays null and nothing is deducted.
