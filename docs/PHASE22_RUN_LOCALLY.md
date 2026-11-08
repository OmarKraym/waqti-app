# Phase 22 — a punch on an approved-leave day cancels that day: run it locally, and how to apply it later

One migration (`supabase/migrations/20261110090000_phase22_leave_punch_cancels_day.sql`, rollback `…_ROLLBACK.sql`), admin panel **12.19.0**, app changes (Home headline, punch notice). **Nothing here is applied to production or deployed.**

## 1. Run the database tests (local only)
```bash
cd supabase
bash local/test-db.sh                                                    # every file, each on a fresh database: TOTAL passed=1371 failed=0
TESTS=tests/phase22_leave_punch_tests.sql bash local/test-db.sh          # only phase 22 (61)
TESTS=tests/phase15_leave_conflict_tests.sql bash local/test-db.sh       # phase 15 (69), now builds its flagged rows directly
```
Same setup as phase 21 (Postgres 16 + PostGIS, clock fixed at 2026-10-31 10:00 with libfaketime).

## 2. Other tests
| What | Command | Last run (2026-11-09) |
|---|---|---|
| Admin panel, unit | `npm test` (panel folder) | 78 / 78 |
| Admin panel, behaviour | `node tests/ui/behavior.mjs .` | 404 passed, 0 failed |
| App | `npx vitest run`, `npx tsc -b`, `npm run build` | 389 / 389, clean, builds |
| App in the browser | `VITE_MOCK=1 npx vite --port 5179`, open `/?onleave=1` | pill «أنت في إجازة معتمدة اليوم» + note + open button; after the punch: «أُلغي هذا اليوم من إجازتك» |

## 3. How to apply it later (needs Omar's explicit «نعم»)
1. Apply the migration with `apply_migration` (one call). **Avoid backslash escapes in the text sent through the tool** (phase 21 learned this: an escape arrives as a raw character and changes the function text); this migration has none.
2. Compare each function with the local text (`select n.nspname||'.'||p.proname, md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where …`):

| Function | `md5(prosrc)` |
|---|---|
| `private.cancel_leave_days` | `6fbb36f3931a105b3e2c651ec5ac6241` |
| `private.record_punch` | `9ea1e7cbcc986bee947e4575fe977444` |
| `public.admin_decide_leave_day` | `8cb177c06a50cbc9c25c73f58eeef91a` |
| `public.admin_list_leave_day_cancellations` | `18a7df27553c92e9c4c61da496db11aa` |
| `public.employee_attendance_state` | `e8d332cb6ab2e88cd1591d326eec23f3` |

   Group fingerprint (`md5(string_agg(md5(prosrc), '' order by proname))` over those five): `af99f3093c44035cd08e356cd9c4d9fd`.
3. Install panel 12.19, deploy the app (`./scripts/deploy-gh-pages.sh`) **after** the migration: an app without the migration simply never sees `leave_today` / `leave_day_cancelled`; a migration without the app shows the old Home line.
4. Real-use test: an employee with an approved leave today opens the app (pill «أنت في إجازة معتمدة اليوم»), punches (notice «أُلغي هذا اليوم من إجازتك»), the admin sees the day in the new card and presses «يوم عمل عادي» or «إرجاعه إجازة».

## 4. Rollback
`…_ROLLBACK.sql` drops the two admin functions and `private.cancel_leave_days`, and restores `private.record_punch` and `employee_attendance_state` to their pre-22 text. Days already cancelled stay cancelled (data) and their events keep `metadata.leave_day` / `leave_decision`.
