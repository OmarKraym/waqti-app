# Phase 20 — the admin adds a forgotten check-in or check-out: run it locally, and how to apply it later

Phase 20 = two migrations (20 `admin_add_punch`, 20b the «أضافه المدير» flag for the employee), admin panel 12.17.0 and a small app change.
**Nothing of it is applied or deployed.** Every test below ran on a throwaway local database.

## 1. Run the database tests (local only, never production)

Needs a local Postgres 16 with PostGIS where you may create databases (`PGHOST/PGPORT/PGUSER`).

```bash
cd supabase
bash local/test-db.sh                                                    # every file in tests/, each on a fresh database
TESTS=tests/phase20_admin_manual_punch_tests.sql bash local/test-db.sh   # only phase 20 (both migrations)
```

Some tests pick dates relative to today and assume a Saturday–Thursday week. The server that produced the numbers below ran with the
clock fixed (libfaketime, Saturday 2026-10-31 10:00); if a test fails only because of the weekday or the hour, do the same.

Each migration has a `_ROLLBACK.sql`. To try one locally: apply everything, run the rollback, apply the migration again, compare the fingerprint (§3).

## 2. Run the other tests

| What | Command (folder) | Result of the last run |
|---|---|---|
| Database, all files | `bash local/test-db.sh` (`supabase/`) | **TOTAL passed=1118 failed=0** (29 files; the phase 20 file: 69, i.e. 66 for `admin_add_punch` + 3 for the 20b flag) |
| Admin panel, unit | `npm test` (panel folder) | 55 / 55 (9 are the new `manual-punch.test.mjs`) |
| Admin panel, behaviour (Playwright, fake server) | `node tests/ui/behavior.mjs .` | 259 passed, 0 failed |
| Admin panel, layout | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir>` (about 4 minutes) | 264 screens, 0 with problems, 0 script errors |
| App, unit | `npx vitest run` (repo root) | 352 / 352 (23 files; 3 are new, in `timecard.test.ts`) |
| App, types | `npx tsc -b` | clean |
| App, production build | `npm run build` | builds |
| Panel zip | `python3 scripts/pack.py <dir>`, then `behavior.mjs` on the unzipped copy | `waqti_admin_12_17.zip` (86 files): 259 passed, 0 failed |
| App in the browser, fake server | `VITE_MOCK=1 npx vite --port 5179`, open `/?history=1&admin=1&policy=none&clock=2026-11-03T06:00:00Z` | «أضافه المدير» shows on today's card after a punch and beside two of the earlier days (360 px wide) |

What the database tests cover: who may call it (anon no, a plain employee `forbidden`, another company's admin `not_found`); every refusal
(`invalid_action`, `reason_required`, `invalid_time` for future / older than 62 days / the exact time of another event / a check-out more than 24 h after its
check-in / another event in between, `open_session`, `overlaps_session`, `unpaired_checkout`, `no_open_session`); a forgotten pair (check-in on an earlier day →
`missed_checkout` and flagged, then the check-out closes it and clears the flag); lateness 20 and early leave 30 shown by `admin_list_attendance` with
`authentication_method 'admin'`; a check-in today with nothing after it → `open`; today with later events → `missed_checkout`; two forgotten pairs on one day;
an inactive employee; an untouched employee stays untouched; one audit row per accepted call (16) and none for refused ones; and (part 2) the employee's
`recent_events` says `by_admin` true exactly on the movements the admin added, with the five old keys and the rest of the state unchanged.

Mutation checks (change the code on purpose, the tests must fail, then restore): 25 mutations of `admin_add_punch` in a first round, then 4 more
(one of the first needed a second try); 2 survived at first ("later events ignored", "reason not stored" for the check-out) and the tests were tightened until
they were killed. 3 mutations of the 20b flag (always true, always false, wrong method). Panel: 8 on the library and 8 on the dialog, all killed
(a test found a real bug on the way: the error text of `no_open_session` was read as `open_session`; fixed).

## 3. Applying on production (ONLY after Omar says «نعم», one part at a time)

State read-only on 2026-11-08, before any phase 20 work reached production:

- `employee_attendance_state`: one overload, raw fingerprint `51e02778b74d5a6f53a796c59e739917` = exactly the phase 14 version in the repository
  (so 20b replaces a known function; the rollback file restores exactly this text).
- `admin_add_punch`: does not exist.

1. **Back up first.** Supabase → Database → Backups: take a manual backup (or confirm today's daily backup exists). Note the time.
2. Apply in this order, **one at a time**, running its check before the next. Plain SQL, a guard block that stops with a clear message if a previous phase
   is missing, one transaction each (all or nothing).
   - **20**  `20261108130000_phase20_admin_manual_punch.sql`
   - **20b** `20261108140000_phase20b_employee_state_admin_flag.sql` (needs 20; adds one key to the employee's state)
3. **Check each one against the local fingerprint.** Run the query on production and compare it with the value from the local database:

```sql
-- 20    expected: 1 row, 71b512a9be0cb099bdff7fecbae66620
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc where proname = 'admin_add_punch';
select has_function_privilege('anon', 'public.admin_add_punch(uuid, text, timestamptz, text)', 'execute');           -- f
select has_function_privilege('authenticated', 'public.admin_add_punch(uuid, text, timestamptz, text)', 'execute');  -- t

-- 20b   expected: 1 row, 755f640ddfdfa54e26719f228211da48   (before 20b it is 51e02778b74d5a6f53a796c59e739917)
select count(*), md5(string_agg(md5(prosrc), '' order by proname)) from pg_proc where proname = 'employee_attendance_state';
```

4. After 20: nothing visible changes until the panel with the new button is installed. After 20b: open the employee app as any employee — the home
   screen must load as before (the extra key is ignored by an app that does not know it).
5. The panel zip `waqti_admin_12_17.zip` is installed by the administrator (outside this repository). The app is deployed separately. Either may go
   first: a panel newer than the database says «هذه الميزة غير متاحة بعد» in the dialog; an app newer than the database shows no label.
6. If something is wrong: `20261108140000_phase20b_employee_state_admin_flag_ROLLBACK.sql` (20b), then `20261108130000_phase20_admin_manual_punch_ROLLBACK.sql` (20).
   They do not delete attendance data. The events already added by the admin stay as history.

A real use test after applying (suggested, with a test employee): add a check-in for yesterday 08:15 with a reason → the toast says the check-out is still
missing and the employee appears in the review card; add the check-out 16:00 → the session closes and the card entry goes; the attendance list shows both
rows marked «أضافه المدير» and the audit log has two `attendance.manual_add` rows.
