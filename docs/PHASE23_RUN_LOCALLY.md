# Phase 23 — what the employee forgot shows up in «حركات تحتاج مراجعة»: run it locally, and how to apply it later

One migration (`supabase/migrations/20261110100000_phase23_forgotten_punches.sql`, rollback `…_ROLLBACK.sql`) and admin panel **12.20.0**. **Nothing of phase 23 is applied to production, deployed or pushed.** The app (employee PWA) is not changed.

What it does: (1) a session left open (check-in, no check-out) reaches the review queue by itself, with the existing «إضافة الانصراف» button; (2) a working day with no check-in at all reaches the same card, with «إضافة الحضور» and «غائب / تجاهل».

## 1. Run the database tests (local only)
```bash
cd supabase
bash local/test-db.sh                                                    # every file, each on a fresh database: TOTAL passed=1417 failed=0
TESTS=tests/phase23_forgotten_punches_tests.sql bash local/test-db.sh    # only phase 23 (44)
```
Same setup as phase 22 (Postgres 16 + PostGIS, clock fixed at 2026-10-31 10:00 with libfaketime). One run at a time: the runner always rebuilds the database `waqti_test`.

## 2. Other tests
| What | Command | Last run (2026-11-09) |
|---|---|---|
| Admin panel, unit | `npm test` (panel folder) | 80 / 80 |
| Admin panel, behaviour | `node tests/ui/behavior.mjs .` | 452 passed, 0 failed |
| Admin panel, layout (every screen, 3 widths) | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir>` | 324 screens, 0 with problems, 0 issues, 0 script errors |
| Migration mutation checks | 19 mutants of the migration (24 h line → 48 h, 7 days → 8, no leave/holiday/decision/grace/created_at/inactive filter, another company, anon grant, the leave note: company holiday counted / wrong day / never used…) | 19 / 19 killed |
| Panel mutation checks | 12 mutants of `review.js` / `attendance.js` / `manual-punch.js` | all 12 killed (P12 first survived: «card hidden when only missing rows»; it got its own test and is killed now) |

## 3. How to apply it later (needs Omar's fresh «نعم» — the answer to «طبّق المرحلة 23»)
1. Apply the migration with `apply_migration` (one call, the exact file text). **Avoid backslash escapes in the text sent through the tool**; this migration has none (checked with grep).
2. Compare each function with the local text (`select n.nspname||'.'||p.proname, md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where …`):

| Function | `md5(prosrc)` |
|---|---|
| `private.close_forgotten_sessions` | `e49dbb6c0b8b8cc66cc232efdcd239c5` |
| `private.missing_checkins` | `b16b865bb5821129ff590cb2fc0cdc8f` |
| `public.admin_dismiss_missing_checkin` | `3093ea20a18e4c2a0617e4c8539805ca` |
| `public.admin_list_missing_checkins` | `1e7c82e904717b8a984bb1bc34fad196` |
| `public.admin_review_queue` | `488c93af61484fe8260bd8a881fc8d72` (and it is **volatile** now, not stable) |

   Group fingerprint (`md5(string_agg(md5(prosrc), '' order by proname))` over those five): `a3af6a6b09e6a4dc39c6ef09a21988fc`.
   **Before** the apply, production's `admin_review_queue` must show `5068880fd716ded5f9c6145130e24bf5` (stable): measured on production on 2026-11-09, it is the same as a local database without phase 23, and as the text the rollback puts back.
3. Check the grants: the two `public.admin_*` functions are executable by `authenticated` only (not `anon`, not `public`); the two `private.*` functions by nobody; the table `attendance_day_decisions` has RLS on and no grant for `anon` / `authenticated`. Run the security advisor: only the usual «authenticated SECURITY DEFINER executable» warning for the two new admin RPCs is expected (each calls `require_company_admin()`).
4. Install panel **12.22** (`waqti_admin_12_22.zip`; it contains 12.20, the «تمت مراجعتها» mark of phase 23b and the leave note of phase 23c). **Order: migration first, panel second.** A panel 12.20 on a database without the migration shows the review card exactly as 12.19 (the new list is asked silently and its absence is ignored); a migration without the panel changes nothing the admin sees except that old open sessions now reach the queue.
5. Real-use test: an employee with a working day and no punch (grace passed) → the admin opens الحضور: the row «لا حركة» appears in «حركات تحتاج مراجعة»; «إضافة الحضور» opens the manual-punch window with the employee and day filled in; «غائب / تجاهل» hides the row. An employee with a check-in from yesterday and no check-out → a «نسي الانصراف» row with «إضافة الانصراف».

## 4. Rulings I made (to be confirmed by Omar)
| # | Ruling | Cost if wrong |
|---|---|---|
| R1 | The open-session trigger is **lazy**: when the admin opens the review queue, every open session of his company is judged. An employee with punch windows on **and** a schedule keeps his own window rule (`close_missed_checkout`); an employee without windows or without a schedule gets a fixed **24 h after the check-in** line. This is wider than Omar's literal «فقط للموظفين الذين ليس لديهم ساعات دوام»: scheduled employees' lapsed sessions now also show without the employee opening the app. | One `elsif` to narrow it; the sessions already closed as missed stay missed (data). |
| R2 | The no-show window is the **last 7 local days**, today included. | Change `generate_series(0, 6)` in `private.missing_checkins`. |
| R3 | A shift that crosses midnight is **not listed** (same as phase 12 lateness). | Those days never show as no-show. |
| R4 | An employee with **no schedule** gets no no-show row (there is no «day he should have come»). | — |
| R5 | «غائب / تجاهل» records only the decision (table `attendance_day_decisions` + audit `attendance.day_absent`). It has **no payroll or deduction effect**. | A later phase can read the table. |
| R6 | «إضافة الحضور» on a no-show row reuses the phase 20 manual-punch window with the employee and the day already chosen. | — |
| R7 | (23c, Omar's pick «يبقى ظاهراً مع ملاحظة») A review row whose local day is covered by **his own** approved leave stays in the queue and carries the leave in the `leave` column; the panel writes «عليه إجازة سنوية، يوم واحد (معتمدة): <day>». Nothing is hidden or written on the movement. A company holiday does not count as «his leave». The case that started it: employee 1021057 punched in on 2026-11-08 09:06, never out, then asked for a leave for that day and it was approved. | Drop the `left join lateral … cov` in `admin_review_queue`; the panel line disappears by itself. |

## 5. Rollback
`…_ROLLBACK.sql` puts the phase 15 text of `admin_review_queue` back (stable again), drops the two public and two private functions and the table `attendance_day_decisions`. Sessions already closed as «missed check-out» stay that way (data), and the absences already recorded vanish with the table.

**How the rollback was proven (2026-11-09):** on a database with every migration applied, the rollback ran in one transaction without error; `admin_review_queue` came back with `md5(prosrc)` `5068880fd716ded5f9c6145130e24bf5` and `stable`, the four functions and the table were gone; applying the migration again gave the five fingerprints and the group fingerprint of §3 again. A second database built **without** phase 23 gave the same `5068880f…` as production does today. Proven again after the phase 23c change (same results; the queue text of §3 is the one with the leave note).
