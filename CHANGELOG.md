# Changelog

## Home: «سجل الدوام» becomes a button with a period picker (2026-11-28) — branch `feature/attendance-history`; not deployed

Omar: the earlier-days log should be a button that opens a window where the employee picks two dates and sees those days; and Home
should be less crowded. The inline log is gone from Home; one quiet row «سجل الدوام» opens a tall bottom sheet: «من» / «إلى» (opens on
the last 30 days up to yesterday; at most 92 days; no future day), «عرض», a totals line («25 يومًا حضور · المجموع 191 س 10 د») and
one row per day (first check-in – last check-out, time worked, «للمراجعة» / «بدون انصراف» / «أضافه المدير»).
Data: a direct read of `attendance_events` for the signed-in employee — the existing policy `events_read_self` (employee_id = auth.uid())
already allows exactly this, so no database change. New `lib/history.ts` (period rules, query window, totals) with 6 tests; mock API
serves a five-month history with `?history=1`. Modal gets an optional `className` (`modal--tall` scrolls inside).

## Requests: «كيف حُسب رصيدك؟» (2026-11-28) — branch `feature/google-colors`; not deployed

Omar: tapping the annual leave number should explain, short and clear, why it shows e.g. 27 days today when none was used.
The number (with a «كيف حُسب؟» chip) opens a bottom sheet: one sentence (the year is earned day by day, about 2.5 days a month),
then the sum line by line — earned up to today (+), carried from last year (+), used (−), recorded outside the app (−), waiting (−) —
the total that matches the card, and how much is still to come this year. Same sum as the server (phase 18a); an older server
without `earned` shows the card as before. New pure helper `annualExplain` with 4 tests (452 in all).

## Employee app: Google colours, name above the clock, no «طلب جديد» on Home (2026-11-28) — branch `feature/google-colors`; not deployed

Omar's request: Google's colours in light and dark, each colour in its right place, calm on the eye; swap the name and the clock;
remove «طلب جديد» from Home; a gentle visual hierarchy (clock and today's card first, then the log and the name).
- **Colours (Google):** blue `#1a73e8` = action and brand (buttons, active tab, links, avatar, focus); green `#188038` = check-in,
  present, approved; red `#d93025` = check-out, reject, errors; yellow `#f9ab00` = waiting, warnings, counts; greys `#202124`…`#f8f9fa`
  for text and surfaces. Dark follows Google's dark theme: page `#202124`, cards `#303134`, pastel fills (`#8ab4f8`, `#81c995`,
  `#f28b82`, `#fdd663`) with dark text, so nothing glows. The clock is plain text colour. All contrast pairs pass `palette.test.ts`.
- **Home:** the name and job are now on top of the hero card (15 px), the date, clock (32 px) and today's shift under them; today's
  card title 17 px and its times 18 px; the log is a step quieter (weekday 14 px). Quick request tiles removed from Home (new requests
  stay on the Requests tab); `QuickRequests.tsx` and its styles deleted, and the unused new-request path from Home to Requests.
- The punch button is green to check in and red to check out (was dark green / red).
- Checks: typecheck, 448 tests, stylelint, build; screenshots of every screen, light and dark (mock API).

## Fix: «إضافة موظف» in the admin panel (2026-11-26) — branch `fix/create-employee-trigger`; migration NOT applied yet

Symptom: adding an employee from the panel always failed (create-employee answered 500 `create_failed`; the function log said
`profile save failed employee_not_found`). No employee could be created since the multi-company change (last account: 2026-10-17).
Cause: Supabase Auth's admin `createUser` inserts the user with `app_metadata = {provider, providers}` and writes the custom
`app_metadata` (`company_id`, `company_role`) with an UPDATE afterwards (supabase/auth `internal/api/admin.go`, `adminUserCreate`).
`on_auth_user_created` ran AFTER INSERT only, so it never saw `company_id` and created no employee row.
Fix (`20261126100000_fix_create_employee_trigger.sql`): the same trigger also runs AFTER UPDATE OF `raw_app_meta_data`; on an update
the function acts only when `company_id` has just appeared and the account has no employee row, so later updates of existing accounts
(password change, reset) do nothing. Edge function and panel unchanged. Tests: `tests/fix_create_employee_trigger_tests.sql` (20;
9 failed before the fix with the same `employee_not_found`), full suite 2020 passed, 1 known phase-15 clock failure. The rollback
restores the production text byte for byte (md5 `5c1ebf4fe0f68ce9d92f8bc91c073685`).

## Dark theme: softer greens (2026-11-25)

Omar: every green in dark mode had a slight, tiring glow. The dark theme now uses low-chroma sage greens instead of saturated mint
(`#6ee7a0`, `#4ade80`, `#15803d` on near-black glow and vibrate): text and the clock `#8fc2a4` / `#a3cfb5`, icons and focus `#7fb495`,
fills `#3e7a58`, tints `#1c2b24`. Light theme unchanged. All contrast pairs still pass `palette.test.ts`.

## Employee app redesign — «Stitch» design (2026-11-24) — branch `feature/ui-redesign-dawam`; local only, nothing deployed

Omar's request (2026-11-24): change the whole app interface to the new design (stitch_arabic_hr_attendance_app: home, requests, profile), keep every service working, and bring everything the old app had and the design lacks into the new style.

- **Look:** deep forest green `#1E352B` with emerald, white hairline cards (16 px corners, no shadows), IBM Plex Sans Arabic + IBM Plex Mono for clock, times and codes, Material Symbols icons (self-hosted SVG paths, `tools/gen-icons.py`). Light theme from the design; the dark theme is derived (same hues). All contrast pairs pass `palette.test.ts`.
- **Navigation:** two tabs, «الرئيسية» and «الطلبات». «الإشعارات» is now a screen opened from the bell on Home and from the profile (`?tab=notifications` links still open it). The bell has a red dot while notifications or location are not set up.
- **Home:** header (avatar + «وقتي» + company → profile; bell), hero card (date, live server clock, today's shift, name, job • department, employee number), «حضور اليوم» (status badge, check-in, check-out, total hours; every punch listed when one waits, was added by the admin or is under review), quick requests, «سجل الأيام السابقة» (scrolls inside, about four rows), punch pill above the tab bar (green with fingerprint / red check-out / grey when not allowed).
- **Requests:** header «طلب جديد» button (was a floating button), «طلباتي / اعتمادات الفريق» switch (only for approvers and overtime managers), status filter pills, plain cards with the approval path in the footer, tinted «رفض / موافقة».
- **Profile:** who card, «الحساب», «ملخص بياناتي», «تفضيلات التطبيق» (language, notifications, theme, fingerprint sign-in), red sign-out.
- **Kept from the old app in the new style:** balances, permissions this month, overtime (mine and team, assign form), new-request form, holidays and reminders, failed punches, forgot-check-in, offline and sync messages, first-run setup, login, password change, device setup, light/dark/auto.
- **Not from the design, on purpose:** the design's 30-day log needs a server change (the state sends the last 10 punches), so the log shows the days the server sends; times stay 12-hour with ص/م as before; no manager name on the profile (the app has no such data); app name stays «وقتي».
- New pure helpers with tests: `todayShift`, `jobLine` (profileSummary), `todayEnds`, `clockDuration`, `dayLabel` (timecard). The hero test of `palette.test.ts` now accepts a solid hero colour. `@fontsource/readex-pro` removed, `@fontsource/ibm-plex-mono` added.
- Checks: typecheck, 448 unit tests, stylelint, production build; built app under its CSP loads both fonts with no violation; screenshots of every screen in light and dark (mock API).

## Phase 28 — custom permissions for system admins, level «مخصص» (2026-11-16) — branch `feature/punch-mode-company-roles`; migration 28 NOT applied; panel 12.27 delivered as a zip (not installed); app not touched; nothing pushed

Omar's request (2026-11-16): different permissions between system admins, chosen by the system manager; the «add company» half of the request was **skipped by him** («تخطى موضوع الشركات»). He chose custom permissions per admin (not only the three fixed levels). Hand-off, fingerprints, rollback proof and how to apply: `docs/PHASE28_RUN_LOCALLY.md`. Design: `docs/superpowers/specs/2026-11-16-admin-custom-permissions-design.md`.

**Found at the first production attempt of phase 26 (2026-11-16, nothing was kept):** `admin_set_leave_year` in production has CRLF line ends, so the patch that adds one line after `begin` found no `LF begin LF` and stopped by design. Phase 26 and its rollback now follow the line-end style of each function (LF functions get exactly the same text as before; checked: fingerprints of an LF build unchanged, phases 26/27/28 tests pass on a CRLF build, rollback gives the identical earlier text). See `docs/PHASE25_26_RUN_LOCALLY.md` §3.2.

### What changes for people
- A new level **«مخصص»** next to the three of phase 26. The owner picks it in Settings ← مديرو النظام and ticks groups in a dialog. Every custom admin always has «الاطلاع العام» (read-only lists, no salaries); the groups add to it: **قرارات الطلبات والإجازات**, **ملفات الموظفين (تشمل الرواتب)**, **النطاق الجغرافي والموقع**, **الحركات اليدوية**. At least one group. Leaving the level deletes the groups.
- Never grantable (owner only): managing admins and levels, company name and settings, deleting an employee, all other settings, new password, adding employees. The other protections of limited levels stay (cannot change an admin's account, password-only sign-in).
- Database: `admin_list_admin_grants`, `admin_set_admin_grants` (owner only, audited, one change at a time per company); the gate `require_company_admin` now asks `private.admin_may_call`. `admin_set_admin_role` and `admin_delete_employee` are patched by text; nothing else changes.

### Found while building
- The first cut of the groups (a «الدوام والنطاق والأجهزة» group) would have left the employee form half refused, because the form calls grace, punch-window and device functions. Found by surveying which functions each screen calls; the groups were re-cut so that each group alone gives working screens, and the panel's strict fake (it refuses any `admin_*` call outside the permission list) opens and saves the employee form with the `employees` group alone.
- Panel 12.26 does not know the level «مخصص» and refuses to open a custom admin's account: install 12.27 before creating the first custom admin.
- Not caused by this work: closing the geofence dialog the moment it opens raises a Leaflet script error (also for the owner). Left as it was.

### Tests
Database whole suite **2000 passed, 1 failed** (39 files; phase 28: 139; the one failure is the clock-dependent phase 15 file, as before; the 38 older files unchanged: 1861 + 139) · **mutation check:** 24 / 24 deliberate breaks of the gate, the set function and the catalogue caught · **rollback proven:** 858 lines identical between a database without 28 and one with 28 then rolled back (the comparison does see the change: 34 lines differ). Panel 12.27: unit 198 / 198, behaviour 733 / 0 (strict fake that refuses calls outside the permission list, run for each group alone, the base alone, and all four), layout levels 96 screens and v12 366 screens, light and dark, 0 problems; 15 / 15 deliberate breaks of the panel code caught; the same unit and behaviour results from the extracted zip.
Honest notes: one mutation first looked like it survived (23 / 24) because its file was left over from before the groups were re-cut: regenerated and rerun, 24 / 24. A behaviour check failed intermittently because the test read the list a moment before the dialog's close event restored the old level (a race in the test, not in the panel): fixed, then 3 consecutive clean runs. No separate reviewer was used.

### Needs Omar's words before anything leaves this machine
«نعم» for migrations in this order: 26 (and 25 if wanted), then 28 · the panel 12.27 is installed by Omar from the zip · «ارفع» for the push (the spec commit and the new commits).

## Phase 27 — «إضافة حركة» and a «تعديل» button on every movement (2026-11-15) — branch `feature/punch-mode-company-roles`; migration 27 NOT applied; panel 12.26 delivered as a zip (not installed); app not touched; nothing pushed

Omar's request (2026-11-15, screenshot of the attendance tab): the button «إضافة حضور» becomes «إضافة حركة» and its dialog chooses حضور or انصراف; every movement gets a «تعديل» button. Hand-off, fingerprint, apply order, rollback and rulings: `docs/PHASE27_RUN_LOCALLY.md`.

### What changes for people
- **«إضافة حركة»** (panel only, no database change): the dialog has a «نوع الحركة» list; the hint, the example reason and the refusal texts follow the kind. It calls the same `admin_add_punch` (phase 20 already accepts both kinds).
- **«تعديل»** (phase 27 + panel): a button in a new «إجراءات» column of the movements table, owner only. The dialog changes the **time only**: same company day, strictly between the employee's previous and next movement, in the past and at most 62 days back, a session of at most 24 hours; a reason of 3 or more letters is required. Lateness, early leave, deduction and overtime are computed from the time when read, so they follow by themselves. The original time and the reason stay in the event data and in the audit log (`attendance.edit_time`). **Not offered, on purpose:** changing the kind, changing the day, deleting. A limited admin level (phase 26) neither sees the button nor can call the function; one row in `private.admin_role_rpcs` would open it for HR.

### Tests
Database whole suite **1861 passed, 1 failed** (38 files; phase 27: 50; the one failure is the clock-dependent phase 15 file, as before) · **rollback proven:** 857 lines of functions, columns, constraints and tables identical between a database without phase 27 and one with it rolled back · phase 27 written red-first, and 8 deliberate breaks of the function were all caught · panel unit **185 / 185**, behaviour **649 / 649**, layout **366 + 366 screens (light, dark) and 66 + 66 (levels)**, 0 problems, stylelint clean; unit and behaviour also pass from the extracted zip · two panel mutants (gating removed, reload removed) were caught.
Note on the proof: a first full run gave 1842 / 2 because the local Postgres had been restarted without `PGHOST`/`PGPORT` in its environment, so the phase 21 test's `dblink` could not connect (identical on a database without phase 27); fixed in the test setup, not in any file of the project.

### Needs Omar's words before anything leaves this machine
«نعم» for migration 27 (after 25 and 26 if they are applied; it needs only phase 20) · «انشر» for the panel 12.26 (part 1 works on today's database; the «تعديل» button says «غير متاحة بعد» until the migration is applied) · «ارفع» for the push.

## Phases 25 and 26 — automatic punch button, and admin levels inside a company (2026-11-15) — branch `feature/punch-mode-company-roles`; migrations 25 and 26 NOT applied; panel 12.25 delivered as a zip (not installed); app changed (not deployed); nothing pushed

Omar's request (2026-11-14): the app stays punch-only (security, geofence, saves the punch; no lateness, no overtime); a company can have limited admin levels; the punch button follows each employee's own shift (middle of the shift, back at 00:00); nothing existing changes, requests stay as they are. Hand-off, fingerprints, apply order, rollback and rulings: `docs/PHASE25_26_RUN_LOCALLY.md`.

### What changes for people
- **Phase 25 (off by default):** Settings ← البصمة ← «الزر التلقائي». On: the server decides check-in or check-out from the employee's own shift (check-out only from the middle of the shift, and only with an open check-in today); the other kind is refused (`mode_mismatch`); a check-in left open on an earlier day is marked «نسي الانصراف» and goes to review. Employee app: the button follows the server, one line says when the check-out opens, and the lateness question after a check-in is gone.
- **Phase 26:** three limited admin levels next to the owner: مسؤول الموارد البشرية, مشرف, مشاهدة فقط. The owner picks the level in Settings ← المدراء. The database allows a limited level only the functions listed for it (default deny); the panel hides what the level cannot do. An older database: everything as before.

### Tests
Database whole suite **1811 passed, 1 failed** (37 files; phase 25: 50, phase 26: 161; the one failure is the clock-dependent phase 15 file, identical on a database without these phases) · **rollback proven:** a database built without 25 and 26 and one built with them and rolled back are identical (842 lines: functions, columns, constraints, tables, grants), assigned levels return to «employee» and the column goes away, and the 35 older test files give the same result on both (1600 passed, 1 clock) · panel unit **176 / 176**, behaviour **600 / 600**, layout **348 + 348 screens (light, dark) and 66 + 66 (levels)**, 0 problems, stylelint clean · app unit **435 / 435**, typecheck, CSS lint and build clean.
Found while proving it: the first version of the phase 25 rollback would have broken every punch (fixed, commit `fix(db): phase 25 rollback restores the real earlier function text`); the first version of the supervisor list allowed cancelling a company leave day (fixed, commit `fix(db): phase 26 supervisor can no longer cancel a company leave day`).

### Needs Omar's words before anything leaves this machine
«نعم» for each migration (25, then 26) · «انشر» for the panel and the app · «ارفع» for the push. An edge-function change (so that the HR level can add employees and reset passwords) is not part of this work and would need «انشر».

## Design-system refactor — tokens, CSS layers, components, leave words (2026-11-10) — branch `refactor/design-system`, panel 12.24 as a zip; nothing pushed, deployed or applied

- **Leave words** follow the panel everywhere: «اضطرارية» and «وضع» (app, panel, database notifications). One migration replaces `private.request_summary`; its rollback restores the old body. Local only: `docs/LEAVE_LABELS_RUN_LOCALLY.md`.
- **Tokens** in three tiers with one shared vocabulary; no literal colour, size, radius or z-index outside token files; the panel gets a dark theme through tokens only.
- **CSS**: `@layer` order, one file per component, BEM, logical properties, no `!important`, no inline styles, stylelint in both.
- **Components**: app primitives (`Button`, `IconButton`, `Chip`, `Card`, `Field`, `EmptyState`, `ConfirmDialog`), hooks and split screens; panel factories (`button`, `badge`, `emptyState`, `confirmDialog`), one `rpc()` wrapper, ES modules only, pure rules in `js/lib` with tests. No `window.confirm` left.
- **Copy**: toasts and empty states without a final full stop; form errors inline, row actions as toasts.
- Report, metrics, visual evidence and decisions: `docs/DESIGN_SYSTEM_REFACTOR.md`. Rules: `docs/CONVENTIONS.md`.

## Phase 24 — request types the admin adds himself: new leave types and new «طلب آخر» types (2026-11-10) — migration 24 NOT applied; panel 12.23 delivered as a zip (not installed); app changed (not built for release, not deployed)

Omar's request (brainstorming 2026-11-09, «تطوير مرونة لوحة إدارة وقتي»): the admin can add **new leave types** and **new «طلب آخر» types** without a developer; existing requests and types stay unchanged; the audience is everyone; **no** attachments, field builder, advanced workflow or wider rules engine. Spec: `docs/superpowers/specs/2026-11-09-custom-request-kinds-design.md`; plan (13 tasks, executed in one session, TDD, one ledger line per task): `docs/superpowers/plans/2026-11-10-custom-request-kinds.md`.
**Nothing of this phase is applied to production, deployed or pushed.** Applying migration 24 needs Omar's fresh «نعم» («طبّق المرحلة 24»); hand-off with the fingerprints, the apply order (**migration, panel, app**), the rulings and the rollback: `docs/PHASE24_RUN_LOCALLY.md`. Contract: `docs/API_CONTRACT.md` §12.

### What changes for people
- **Admin panel 12.23 — Settings ← «أنواع الطلبات»:** add, edit, switch off and delete (only when no request used it) a kind. A **leave kind** has the days per year (empty = not limited, 0 = no days), who sees it (everyone / women / men) and «السبب إلزامي». An **«other» kind** has how its date is asked: one day / a period / no date. Each kind has a name, an order and an on/off switch.
- **Admin panel — «مسار الموافقات»:** every «other» kind gets its own approval path (a leave kind follows the leave path). **Employee card — leave tab:** the days of this one employee for each leave kind (empty = the kind's default; only changed values are saved; shown for existing employees).
- **Requests everywhere** (requests tab, HR decision window, Excel): titled with the kind's name («إجازة حج», «سلفة»); a request of a no-date kind shows «بدون تاريخ» and marks no day on the daily sheet.
- **Employee app — new request:** under «إجازة», the kinds appear in an «إجازات أخرى» group with a line «المتبقي لك: N أيام من M هذه السنة» (and «السبب (مطلوب)» when the kind says so); under «طلب آخر», a «النوع» list appears when kinds exist, and the date field follows the kind (one «التاريخ», a period, or none). Used or waiting days of a kind join the «other types» line of the balances. Without kinds the form is exactly as before.
- **Database:** two tables (`custom_request_kinds`, `custom_kind_entitlements`), `requests.custom_kind_id`, `approval_steps.custom_kind_id`; six new functions; eight replaced (`employee_submit_request` gets an eleventh argument `p_custom_kind_id`; `request_chain` and `admin_set_approval_chain` a fourth; `apply_decision` re-checks a custom leave against **its kind's** balance at final approval; `request_json`, `request_summary`, `employee_requests_overview`, `admin_get_approval_chains` carry the kinds).

### Safe on both sides of the apply
A new panel or app on a database **before** phase 24 degrades silently (the pane says «غير متاح بعد»; no new argument is sent for built-in requests; the overview has no `custom_kinds`, so the form is today's). The one transition effect: an **old app** shows «إجازة undefined» for a custom leave request it meets in a manager's inbox, until the app is replaced (ruling R9).

### Tests
Database **1660 / 1660** (phase 24 file: 243 assertions; the full suite needs the local clock between 12:00 and 13:00 — older phases are time-of-day dependent) · 21 / 21 migration mutants killed · rollback proven (1367 + 50 = 1417 passed on a rolled-back database; with a custom request present the rollback refuses) · panel unit **106 / 106**, behaviour **518 / 518**, layout audit **348 screens, 0 problems** · app unit **423 / 423**, typecheck and build clean, request form checked at 390 px in mock mode (41 checks) · production fingerprints of the eight replaced functions recorded read-only (three differ from local only in line endings).

## Phase 23c — a review row on a day with an approved leave says «عليه إجازة معتمدة» (2026-11-09) — migration 23 amended (not applied); panel 12.22 delivered as a zip (not installed)

Reported by Omar with screenshots (2026-11-09): employee 1021057 (عمر امحمد كريم) still sat in «حركات تحتاج مراجعة» as «دخول 09:06 · بدون خروج» although his one-day annual leave for 2026-11-08 was approved.
Production (read only): he punched in on 2026-11-08 09:06 and never out; at 16:15 he asked for a leave for that same day and it was approved at 16:40; his session was closed as «نسي الانصراف» in the afternoon. Approving a leave never looked at the review row, so the row stayed. Of the 4 rows in the queue this was the only one covered by a leave.
Omar's pick among three: **«يبقى ظاهراً مع ملاحظة»**.

- **Database (inside migration 23, which is not applied yet, so there is no second migration):** `admin_review_queue` fills its existing `leave` column with the employee's own approved leave that covers the local day of the row (not a company holiday). Nothing is hidden or written.
- **Admin panel 12.22:** the row keeps its reason («بدون خروج») and its buttons («إضافة الانصراف» and «قبول»), and gets a line «عليه إجازة سنوية، يوم واحد (معتمدة): 2026-11-08». A punch that landed on a leave keeps its own buttons (phase 15/22).
- **Needs:** migration 23 applied for the line to appear (on the current database the panel looks as before). New fingerprint of `admin_review_queue`: `488c93af…`; group `a3af6a6b…` (`docs/PHASE23_RUN_LOCALLY.md` §3).
- **Tests:** database **1417 / 1417** (phase 23: 44, 8 new) · panel unit 80 / 80 · behaviour 452 / 452 · layout audit 324 screens, 0 problems · mutants: 3 on the migration part and 6 on the panel, all killed · rollback proven again. `waqti_admin_12_22.zip` carries 12.20, 12.21 and 12.22.
- **Ruling R7:** a company holiday is not «his leave» (no note); the movement and its session are not touched.

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

Database **1417 / 1417** (33 files; phase 23: 44) · panel unit 78 / 78 · panel behaviour 436 / 436 · layout audit 312 screens, 0 with problems, 0 issues, 0 script errors · mutation checks: 16 on the migration (all killed), 12 on the panel (all killed; P12 «card hidden when only missing rows» survived first, got its own test, and is killed now) · app untouched (389 / 389 as in phase 22).

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
