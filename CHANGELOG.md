# Changelog

## Phase 23b — a movement the admin already reviewed says «تمت مراجعتها», not «للمراجعة» (2026-11-09) — panel 12.21 only; no database change; delivered as a zip (not installed)

Reported by Omar with a screenshot (2026-11-09): the check-out of employee 1021007 on 2026-11-08 16:02 showed «للمراجعة · انصراف بدون حضور مسجّل» in the attendance table but was not in «حركات تحتاج مراجعة».
Production (read only) showed the queue was right: the admin had already added the missing check-in on 2026-11-08 (`needs_review = false`, `metadata.review.action = add_check_in`). The table was wrong: `reviewLabel` (`export.js`) printed the `suspect` reasons even after the review.

- **Attendance table and Excel column «المراجعة»:** a movement that carries a flag which forces a review (a `suspect` entry, or no fingerprint support) and is no longer waiting (`needs_review = false`) now shows a grey **«تمت مراجعتها»** and no reason. A movement that still waits is unchanged. «دون اتصال» alone never counted as a review.
- **Production check:** all 11 flagged events there are reviewed ones (`needs_review = false` and a `review` entry), so the rule matches the real data; the queue itself is untouched.
- **Tests:** panel unit 79 / 79, behaviour 442 / 442, layout audit 318 screens, 0 problems; 7 mutants (4 of the label rule, 2 of the table, 1 of unknown flags), all killed. `waqti_admin_12_21.zip` carries 12.20 too (supersedes `waqti_admin_12_20.zip`).

## Phase 23 — what the employee forgot shows up in «حركات تحتاج مراجعة»: a forgotten check-out and a check-in nobody made (2026-11-09) — migration 23 NOT applied; panel 12.20 delivered as a zip and superseded by 12.21 (not installed); nothing deployed or pushed

One database migration (**23**) and admin panel **12.20.0**. Omar's request (#71): a forgotten check-out in a session that is still open appears in the review list with a button to add the check-out by hand, and a forgotten check-in appears there too with a button to add the check-in by hand.
His answers: the open-session rule for «employees without fixed hours», the missing check-in «after the grace period has passed», and a «غائب / تجاهل» button that hides the row.
**Nothing of this phase is applied to production, deployed or pushed.** Applying migration 23 needs Omar's fresh «نعم»; hand-off with the fingerprints: `docs/PHASE23_RUN_LOCALLY.md`. Contract: `docs/API_CONTRACT.md` §11.

### What changes for people

- **Open session nobody closed.** When the admin opens الحضور, every open session of his company is judged. A window-rule employee (punch windows on and a schedule) is judged by his own check-out time, as before; an employee without windows or schedule is judged by one fixed line: **24 hours after the check-in**.
  A lapsed session becomes «missed check-out», flagged for review, and the row has the existing **إضافة الانصراف** button (phase 20c).
- **Check-in nobody made.** A working day of the last **7 days** with no movement at all, after the grace period of the shift start, not a holiday, not an approved leave, not before the employee was created: a row «لا حركة» in the same card with **إضافة الحضور**
  (the phase 20 manual-punch window opens with the employee and the day filled in) and **غائب / تجاهل** (hides the row; the decision is stored with who and why, and audited `attendance.day_absent`; **no payroll effect**).
- The card count and the title now include these rows. On a database without migration 23, panel 12.20 behaves exactly like 12.19.

### Tests (all local, 2026-11-09)

Database **1409 / 1409** (33 files; phase 23: 36) · panel unit 78 / 78 · panel behaviour 436 / 436 · layout audit 312 screens, 0 with problems, 0 issues, 0 script errors · mutation checks: 16 on the migration (all killed), 12 on the panel (all killed; P12 «card hidden when only missing rows» survived first, got its own test, and is killed now) · app untouched (389 / 389 as in phase 22).

### Rulings

- R1. The open-session rule is **lazy and wider than Omar's literal answer**: it runs when the admin opens the queue and also catches scheduled employees' lapsed sessions (their own window rule). Cost if wrong: narrow one `elsif`.
- R2. No-show window = last 7 local days, today included. R3. A shift crossing midnight is not listed (as phase 12 lateness). R4. No schedule → no no-show row.
- R5. «غائب / تجاهل» records only the decision: no payroll or deduction effect. R6. «إضافة الحضور» reuses the phase 20 manual-punch window.

## Phase 22 — a punch on an approved-leave day cancels that day (no review); the admin may restore it; «you are on leave today» and «you checked in» on Home (2026-11-09) — migration 22 applied to production 2026-11-09; app not deployed; panel 12.19 delivered as a zip (not installed)

One database migration (**22**), admin panel **12.19.0** and app changes. Omar's requests: the Home pill said «لم تسجّل حضورك اليوم» with a check-in on the card (#69), and an employee on an approved leave must not be asked to punch,
must not be put in review when he does, and his leave for that day goes when he punches (#70). His answers: the day is cancelled **from the first punch**, the admin can decide «leave or normal day», the employee and the audit log are told.
**Migration 22 was applied to production on 2026-11-09 after Omar's «نعم»** (Supabase version `20261109050730`, name `phase22_leave_punch_cancels_day`): before it, `record_punch` and `employee_attendance_state` had the pre-22 text and the three new functions did not exist; after it, all five fingerprints and the group fingerprint matched the local text, the two admin functions are executable by `authenticated` only (not `anon`, not `public`), `private.cancel_leave_days` by nobody. The security advisor shows only the usual «authenticated SECURITY DEFINER executable» warning for the two new admin RPCs, like every other admin RPC (each calls `require_company_admin()`). Not yet done: deploy of the app, install of panel 12.19, the real-use test of §3.4.
Hand-off: `docs/PHASE22_RUN_LOCALLY.md`. Contract: `docs/API_CONTRACT.md` §10.

### What changes for people

- **Employee app, Home:** with a check-in and no check-out the pill says «حضرت الساعة 9:06 ص ولم تسجّل الانصراف» (the latest stamped movement decides) instead of «لم تسجّل حضورك اليوم». On an own approved leave with no punch yet it says
  «أنت في إجازة معتمدة اليوم» and a line that punching cancels that day. The punch button is **not** closed because of the leave (only the shift window closes it, as before). After the punch: «تم تسجيل الحضور… أُلغي هذا اليوم من إجازتك.»
- **Database:** the first punch of a local day that falls on a leave the employee asked for is saved **without review**; that day is cancelled from the leave (whole leave if it was one day; a day at the start or end shortens it; a day in the
  middle splits it, same rule as phase 15), the balance comes back by itself, the employee gets «أُلغي يوم من إجازتك» (or «أُلغيت إجازتك»), audit `leave.cancelled_by_punch`. Other review reasons (outside the zone, no fingerprint…) still apply.
  A leave **the company granted** (holidays, `company_leave_day_id`) keeps phase 15: flagged for the admin, nothing cancelled.
- **Admin panel 12.19, الحضور:** a new card «أيام إجازة أُلغيت لأن الموظف بصم فيها» with **يوم عمل عادي** / **إرجاعه إجازة** (a one-day approved request again, balance counted again, employee told; audit `leave.day_restored` / `leave.day_normal`).
  A later punch the same day does not cancel a restored day again.

### Tests (all local, 2026-11-09)

Database **1373 / 1373** (32 files; phase 22: 63; phase 15: 69, rebuilt on direct flagged rows) · panel unit 78 / 78 · panel behaviour 404 / 404 · app 389 / 389, types clean, build OK · mutation checks: 6 on the migration, 8 on the panel module, all killed.

### Rulings

- R1. Omar's typed answer («تلغى من أول الحضور») and his pick «تبقى الإجازة» for a check-in with no check-out contradict each other: the typed answer wins (cancel at the first punch); «the leave stays» is covered by the admin's «إرجاعه إجازة».
- R2. The admin's decision has its own list and RPC (the old review queue is `needs_review`-based, and the employee must not be «in review»).
- R3. Company-granted leave days keep phase 15 (an employee working a holiday must not be told his leave was cancelled).
- R4. `private.cancel_leave_days` copies the split loop of `admin_resolve_leave_conflict` (left untouched: 1313 tests stand on it).
- Found on the way: two panel checks («manual punch: no reason / reason too short») failed after midnight because «08:15 today» was in the future; they now use yesterday (they are not related to this phase and also failed on the delivered 12.18).

## Phase 21 (+ 20b, 20c) — delete a work place or an employee, the forgotten check-out from the review window, the install line (2026-11-08) — migrations 20b, 20c and 21 APPLIED to production; panel 12.18 not installed, app not deployed

Two database migrations (**20c**, **21**), admin panel **12.18.0** (it also carries the 12.17 panel: `waqti_admin_12_18.zip` supersedes `waqti_admin_12_17.zip`) and an app change.
**20b, 20c and 21 were applied to production on 2026-11-08 after Omar's «طبق أي شيء جاهز»** (each checked against the local fingerprint; one function was written again because a backslash escape had arrived as a raw character: see `docs/PHASE21_RUN_LOCALLY.md` §3). Nothing is visible to anyone until the panel 12.18 is installed and, for the install line, the app is deployed. Procedure and fingerprints: `docs/PHASE21_RUN_LOCALLY.md`.
Contract: `docs/API_CONTRACT.md` §8b and §9.

### What changes for people

- **Admin panel → الإعدادات → أماكن العمل والنطاقات → «حذف».** A place with **active** employees is deleted only after the admin picks another place to move them to (they follow its geofence, except those with an
  individual one); with only inactive employees on it, it is deleted and they stay on it as history; an empty one goes after a confirmation. The name can be used again. The employee form lists only existing places;
  an employee whose place was deleted must be given a new one before the form saves.
- **Admin panel → الموظفون → ⋯ → «حذف الموظف»** (not on your own row). The admin types the employee's name to confirm. He leaves the lists, his account stops at once, his phone is unbound and his push subscriptions are
  removed; his attendance, requests and audit rows stay in the reports under his name. **His number and e-mail stay reserved.** The server refuses, and the dialog says why in words, when he is an admin, has an open
  session, has pending requests, is the direct manager of others, or is a named approver in an approval chain. Audit: `employee.delete`, `work_location.delete`.
- **Admin panel → حركات تحتاج مراجعة → «إضافة الانصراف»** (20c): the forgotten check-out is added from the review window, exactly like «إضافة الحضور» for a missing check-in: it corrects the flagged movement,
  closes that very session and takes it out of the queue (after the check-in, at most 24 h later, not in the future, nothing in between). The general dialog «إضافة حضور أو خروج» is now **«إضافة حضور»** only.
- **Employee app:** the «install the app» button moved out of Home to the **login screen** (Omar's decision): Chrome / Android shows «تثبيت»; iPhone shows «كيف؟» with the existing Share → Add to Home Screen sentence.
  Nothing inside the app, and nothing when it is opened as the installed app. Closing it hides it for the session. The browser's install event is captured at start-up (it comes once, early).

### Tests (all local, 2026-11-08)

Database **1313 / 1313** (31 files; phase 20c: 48, phase 21: 147) · panel unit 78 / 78 · panel behaviour 381 / 381 (also on the unzipped zip) · panel layout 300 screens (on the unzipped zip), 0 with problems, 0 script errors ·
app 376 / 376, types clean, build OK · mutation checks on all the new code: all killed (details in `docs/PHASE21_RUN_LOCALLY.md` §2). Two real bugs were found by the new tests on the way and fixed test-first
(Enter pressed twice in the employee-delete dialog sent two requests; after a refusal that redrew the places list, a later success in the same dialog left the old list on screen).

### Rulings (decided while building; each costs little to change)

- R1. The employee number and e-mail stay reserved after deletion (unique constraints and the auth user remain): reusing them would mean editing history. The dialog says so.
- R2. Deleting an employee is refused, not worked around, when he has an open session, pending requests, reports to him as direct manager, or is a named approver; the admin resolves those first.
- R3. An admin cannot be deleted (remove the admin role first) and nobody can delete himself.
- R4. Deleting a place with active employees requires choosing another place; the move copies the new place's geofence the same way `admin_save_employee_profile` does (an individual geofence stays).
- R5. (Omar) The check-out is recorded only from the review window; `admin_add_punch` stays in the database unchanged. **Open point:** a check-out forgotten on a session that is still «open» with the punch windows off is never flagged, so it has no path in the panel.
- R6. The review check-out is a correction (`source: admin_correction`, `corrects_event`), audited as `attendance.review_add_check_out`, with the phase 20 time limits.
- The install line lives on the login screen only (Omar, 2026-11-08), replacing the plan's «top of Home».
- Rolling back 21 keeps the `deleted_at` columns (the record of what was deleted); deleted places get a name suffix so the old unique index can come back.

### Deferred minors

- An inactive employee whose place was deleted still shows the old place name in the employees list (his history keeps it by design).
- `js/settings/admins.js` has the same "spent reload after a stale refusal" pattern the places pane had; not touched.

## Phase 20 — the admin adds a forgotten check-in or check-out (2026-11-08) — migration 20 APPLIED to production; 20b, panel and app NOT yet

Two database migrations, admin panel 12.17.0 and a small app change. **Migration 20 (`admin_add_punch`) was applied to production on 2026-11-08 after Omar's «نعم»**
(migration name `phase20_admin_manual_punch`; fingerprint `71b512a9be0cb099bdff7fecbae66620` matched the local value; `anon` cannot execute it, `authenticated` can;
`employee_attendance_state` untouched, still `51e02778…`). **20b (`by_admin` for the employee), the panel zip and the app are NOT applied / installed / deployed.**
Nothing is visible to anyone until the panel 12.17 is installed. Procedure and checks: `docs/PHASE20_RUN_LOCALLY.md`. Decisions below were approved by Omar on 2026-11-08 («نعم أ»).

### What changes for people

- **Admin panel → الحضور → «إضافة حضور أو خروج».** The admin picks the employee (the one chosen in the filter comes preselected), the kind, the day, the time on the
  company clock, and writes a **reason (required)**. The movement is saved like a normal punch: **lateness, early leave and the phase 19 deduction are counted
  by the time the admin writes** (option «أ»). It is marked «أضافه المدير» in the movements table and written to the audit log (`attendance.manual_add`) with the reason.
- **Check-in:** refused when the employee has an open session, when the time is inside a closed session of his, when it equals another event's time, or right before a
  check-out with no check-in the same day (that case belongs to the review queue). Today with nothing after it → the session stays **open** (he is still at work);
  an earlier day, or later events exist → the session is `missed_checkout` and the check-in is flagged for review until its check-out is added.
- **Check-out:** closes the latest open / waiting session that started before the time, if that is at most **24 h** earlier and no other event lies in between. It clears the
  «missed check-out» flag (and the review flag, unless something else needs a look).
- **Limits:** the time is in the past and at most **62 days** back. The employee may be deactivated (payroll can need a former employee's last days). Nothing
  existing is changed or deleted.
- **Employee app (20b):** a movement the admin added shows «أضافه المدير» on today's card and beside the day in «الأيام السابقة».

### Tests (all local, 2026-11-08)

Database 1118 / 1118 (29 files; phase 20: 69) · panel unit 55 / 55 · panel behaviour 259 / 259 (also on the unzipped `waqti_admin_12_17.zip`) ·
panel layout 264 screens, 0 problems · app 352 / 352, types clean, build OK · mutation checks on the new code: all killed (see `docs/PHASE20_RUN_LOCALLY.md` §2).

### Rulings (decided while building; each costs little to change)

1. Reason is required, 3–500 characters after trimming. *If wrong:* a one-line change in the function and the dialog.
2. 62 days back, 24 h check-in→check-out. *If wrong:* a number in the function (and `MAX_DAYS_BACK` in the panel).
3. A check-in with later events, or on an earlier day, is `missed_checkout` and flagged — it uses the existing «missed check-out» path instead of a new status.
4. `unpaired_checkout` is refused instead of guessed: the review queue (`admin_resolve_review`) already solves a check-out that has no check-in.
5. The deactivated employee is allowed (payroll). The employee must still belong to the admin's company (`not_found` otherwise).
6. `by_admin` is derived from `authentication_method = 'admin'`, so a correction made in the review queue (phase 14) also shows «أضافه المدير».

### Files

| Where | Files |
|---|---|
| Database | `supabase/migrations/20261108130000_phase20_admin_manual_punch.sql` (`admin_add_punch`), `20261108140000_phase20b_employee_state_admin_flag.sql` (`employee_attendance_state` + `by_admin`) (+ a `_ROLLBACK.sql` for each) |
| DB tests | `supabase/tests/phase20_admin_manual_punch_tests.sql` (both migrations) |
| Admin panel (outside this repo) | `waqti_admin_12_17.zip`: `js/manual-punch.js` (dialog), `js/lib/manual-punch.js` (pure rules), `js/attendance.js`, `index.html`, `tests/` |
| App | `src/lib/types.ts`, `src/lib/timecard.ts`, `src/screens/Home.tsx`, `src/styles.css`, `src/lib/timecard.test.ts` |
| Docs | `docs/API_CONTRACT.md` §1 and §8, `docs/PHASE20_RUN_LOCALLY.md`, this file |

### Risks

- A panel newer than the database: the dialog says «هذه الميزة غير متاحة بعد» (the call fails with "function not found"); nothing else is affected.
- An app newer than the database (no `by_admin`): the label simply does not show. A database newer than the app: the extra key is ignored.
- Rolling 20b back puts the phase 14 version of `employee_attendance_state` back (the label disappears). Rolling 20 back drops the function; the events it created stay as history.

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
