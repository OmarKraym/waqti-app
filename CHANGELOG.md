# Changelog

## Phase 19 — attendance rules (2026-11-08) — database APPLIED to production; app and panel NOT deployed

Three database migrations, admin panel 12.16.0 and an app change. **The three migrations (19a, 19b, 19c) were applied to
production on 2026-11-08, one at a time, each checked by function fingerprint** (see `docs/PHASE19_RUN_LOCALLY.md` §3). The app
and the panel zip are **not** deployed yet. Apply order and checks: `docs/PHASE19_RUN_LOCALLY.md`.

### What changes for people

- **Company late rule** (19a). The grace period can count in one of two ways. `all_after_grace` (the default, today's
  behaviour): inside the grace nothing counts; beyond it ALL the minutes since the shift start count. `beyond_grace`: only the
  minutes AFTER the grace count. One rule for late arrival and early leave. Nothing changes for a company until its admin picks
  the other rule in the panel (الإعدادات ← الدوام ← «فترة السماح»).
- **Late deduction policies** (19b). Per company, dated, either *proportional* (every N counted minutes = M minutes of pay,
  rounded up / down / nearest to a step) or *tiers* (from–to minutes = deduction). The policy in force on a day is the latest
  one that started on or before it; a day before the first policy deducts nothing. Editable only while it has not started (الإعدادات ← الدوام ← «سياسة الخصم»).
  The deduction is in **minutes of pay**, not money. The attendance list (panel) shows it on each first arrival: «خصم N د»,
  «مبدئي: خصم N د» (a justification is pending) or «معفى» (an approved justification covers the arrival).
- **The app asks the server** (19c). After an online check-in the app calls `employee_late_status` and offers the late-arrival
  justification only when the server says so. When he is late but cannot request one (none left this month, delay above the
  longest allowed, already requested) a dismissible line says why, with the expected deduction when there is one. The monthly
  count is no longer decided in the app.
- **The monthly limit holds under a race** (19c). A table trigger refuses a pending permission request that would push the
  month over the type's limit, even for two simultaneous inserts (`permission_limit`).

### Files

| Where | Files |
|---|---|
| Database | `supabase/migrations/20261108100000_phase19a_late_rule.sql`, `20261108110000_phase19b_deduction_policies.sql`, `20261108120000_phase19c_late_status.sql` (+ a `_ROLLBACK.sql` for each) |
| DB tests | `supabase/tests/phase19a_late_rule_tests.sql`, `phase19b_deduction_policies_tests.sql`, `phase19c_late_status_tests.sql`; `supabase/local/concurrency-limit.sh` |
| Admin panel (outside this repo) | `waqti_admin_12_16.zip`: `js/lib/deduction.js`, `js/settings/deductions.js` (new pane), `js/settings/grace.js`, `js/attendance.js` |
| App | `src/lib/lateOffer.ts`, `types.ts`, `api.ts`, `supabaseApi.ts`, `mockApi.ts`, `src/screens/Main.tsx`, `src/styles.css` |
| Docs | `docs/API_CONTRACT.md` §5–§7, `docs/PHASE19_RUN_LOCALLY.md`, this file |

### Database objects

- 19a: column `companies.late_rule`; functions `private.chargeable_minutes`, `private.punch_lateness` (same signature, reads the rule),
  `public.admin_get_grace_settings` (also returns `late_rule`), `public.admin_set_late_rule(text)`.
- 19b: table `public.deduction_policies` (RLS on, no direct access); `private.json_int`, `deduction_params_clean`, `deduction_params_ok`,
  `deduction_calc`, `late_deduction`, `deduction_policy_json`, `punch_deduction`; `public.admin_list_deduction_policies`,
  `admin_save_deduction_policy`, `admin_delete_deduction_policy`, `admin_preview_deduction`; `public.admin_list_attendance` is
  dropped and recreated with two columns added at the END (`deduction_minutes`, `deduction_state`).
- 19c: `public.employee_late_status(uuid)`; `private.requests_limit_guard()` and trigger `requests_limit_guard` on `public.requests`
  (before insert, pending permission rows only).

### Rollback

Reverse order, each file restores the previous state and leaves the older phases intact (tested: same fingerprint after
re-applying, the older phase tests pass on the rolled-back database):
`20261108120000_phase19c_late_status_ROLLBACK.sql` → `20261108110000_phase19b_deduction_policies_ROLLBACK.sql` →
`20261108100000_phase19a_late_rule_ROLLBACK.sql`. Rolling back 19b drops `deduction_policies` and its policies (the data in it).
No historical attendance data is touched by any of the three, in either direction.

### Risks and things to know

- **Report numbers change only if a company switches to `beyond_grace`.** Lateness is computed when a list or report is read, not
  stored, so switching also changes how OLD days read. The panel says so next to the setting. Companies that never switch see
  exactly what they saw before.
- The new trigger takes one advisory lock per employee for each pending permission insert, then counts the month again. Cost: one
  lock and one count per request; none for any other table or request type.
- `admin_list_attendance` is dropped and recreated (a return type cannot change in place). Callers that name columns are not
  affected; the two new columns come last.
- An app or panel newer than the database keeps working: the app gets "function not found" and shows nothing extra; the panel shows
  «غير متاح بعد» in the deduction pane and hides the rule choice.
- `employee_late_status` does not look at overlap with the employee's other leave or permission ranges, so it can say `offer` and
  the request can still be refused with `overlapping_request` (the app already shows that message).

### Not done (on purpose or left for later)

- No money: the deduction is minutes of pay; turning it into money belongs to payroll.
- The Excel exports have no deduction column yet.
- The app and the panel are not deployed. Until they are, nobody sees the new screens; the database already answers the new calls.

### Tests (all run locally in this session)

See the numbers in `docs/PHASE19_RUN_LOCALLY.md` (last section) — they are copied from the actual runs.
