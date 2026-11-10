# Design-system refactor (2026-11-10) — app branch `refactor/design-system`, panel 12.24

Brief: the four workstreams (tokens, CSS architecture, components, copy and leave labels). Rules: `docs/CONVENTIONS.md`.
**Nothing is pushed, deployed or applied to production.** The one database change (leave labels) is
`supabase/migrations/20261112090000_leave_labels.sql` + `_ROLLBACK`, tested locally only (`docs/LEAVE_LABELS_RUN_LOCALLY.md`).

## Before / after metrics
Measured by the same script on both trees. Remaining counts are explained below the table.

| Metric | App before | App after | Panel before | Panel after |
|---|---:|---:|---:|---:|
| css lines | 1252 | 1482 | 459 | 620 |
| classes defined | 265 | 285 | 124 | 123 |
| custom properties | 84 | 187 | 38 | 137 |
| literal colours in rules | 14 | 0 | 21 | 0 |
| literal colours in token defs outside token files | 171 | 0 | 0 | 0 |
| rgba() total | 48 | 42 | 12 | 23 |
| distinct font-size | 9 | 9 | 16 | 7 |
| literal font-size | 1 | 0 | 16 | 0 |
| distinct radius | 14 | 8 | 7 | 5 |
| literal radius | 10 | 1 | 5 | 1 |
| distinct spacing px | 16 | 0 | 11 | 0 |
| distinct z-index | 6 | 6 | 2 | 2 |
| literal z-index | 6 | 0 | 2 | 0 |
| distinct transition | 10 | 9 | 2 | 2 |
| breakpoints | 1 | 1 | 4 | 3 |
| physical properties | 3 | 0 | 2 | 0 |
| !important | 2 | 0 | 2 | 0 |
| undefined classes | 12 | 0 | 11 | 2 |
| unused classes | 2 | 1 | 7 | 0 |
| raw buttons | 68 | 23 | 129 | 16 |
| button class combos | 19 | 6 | 9 | 2 |
| window.confirm | 2 | 1 | 16 | 1 |
| inline styles | 2 | 0 | 17 | 3 |
| window.Waqti* refs | — | — | 15 | 0 |

What remains, on purpose:
- App `window.confirm` 1, panel 1: the word in a code comment (`ConfirmDialog`, `confirmDialog` say what they replace). No call remains.
- App unused class `stamp`, panel undefined `toast--`: built in a template string (`stamp--in`, `toast--error`); the script cannot see them.
- Literal radius 1 in each: `0`.
- Panel inline styles 3: the menu's position, computed on every open (R16).
- `rgba()` left: inside token files only (shadows and scrims).
- App raw buttons 23 / panel 16: tabs, segments, the punch button, switches and the like are their own components, not button variants (R19).

## Visual evidence
Screens: app at 390 px, light and dark (40 shots); panel at 390/600/720/800/1024/1280 px, 58 steps each (348 shots), light, plus the same in dark (new; the old panel had no dark theme).
Panel before and after were shot back to back at the same clock (the fake data follows the clock).

| Set | Shots | Identical | Changed < 1 % | Changed ≥ 1 % | Why they change |
|---|---:|---:|---:|---:|---|
| App, before → after | 40 | 12 | 28 | 0 | WS1 only: the tab pill (56×32) and paddings snapped to the 4-px grid. WS2 and WS3 steps were pixel-identical each time. |
| Panel, before → after (light) | 348 | 0 | 1 | 347 | WS1: 16 font sizes became 7 (R6); text a step smaller moves the lines under it. Muted text darker (R8). |
| Panel dark | 348 | — | — | — | New. Layout checks: 0 problems. |

Layout checks on every panel screen: 0 problems, 0 script errors, light and dark.

## Tests (final run)
App: vitest 426/426, `tsc -b --noEmit` clean, `npm run lint:css` clean, build OK. Panel: node 155/155, behaviour 519/519, layout 348 + 348 (light, dark), lint:css clean. Database: 1669/0 (with the leave-labels migration and its 9 checks).

## Panel 12.24 — changed files
Compared with the 12.23 folder (`diff -rq`; `package-lock.json` left out):

```
Files BEFORE/README.md and ./README.md differ
Only in BEFORE: config.js
Only in BEFORE: employee_import.js
Only in BEFORE: export.js
Files BEFORE/index.html and ./index.html differ
Files BEFORE/js/attendance.js and ./js/attendance.js differ
Files BEFORE/js/auth.js and ./js/auth.js differ
Only in ./js: config.js
Files BEFORE/js/core/api.js and ./js/core/api.js differ
Files BEFORE/js/core/dom.js and ./js/core/dom.js differ
Files BEFORE/js/core/ui.js and ./js/core/ui.js differ
Files BEFORE/js/employee-delete.js and ./js/employee-delete.js differ
Files BEFORE/js/employee-form.js and ./js/employee-form.js differ
Files BEFORE/js/employees.js and ./js/employees.js differ
Files BEFORE/js/geofence.js and ./js/geofence.js differ
Files BEFORE/js/import.js and ./js/import.js differ
Files BEFORE/js/leave-days.js and ./js/leave-days.js differ
Files BEFORE/js/leave-years.js and ./js/leave-years.js differ
Only in ./js/lib: attendance-filters.js
Only in ./js/lib: employee-form-data.js
Only in ./js/lib: employee-import.js
Only in ./js/lib: excel-export.js
Files BEFORE/js/lib/guard.js and ./js/lib/guard.js differ
Only in ./js/lib: review-data.js
Files BEFORE/js/managers.js and ./js/managers.js differ
Files BEFORE/js/manual-punch.js and ./js/manual-punch.js differ
Files BEFORE/js/overtime.js and ./js/overtime.js differ
Files BEFORE/js/requests.js and ./js/requests.js differ
Files BEFORE/js/review.js and ./js/review.js differ
Files BEFORE/js/settings/admins.js and ./js/settings/admins.js differ
Files BEFORE/js/settings/approvals.js and ./js/settings/approvals.js differ
Files BEFORE/js/settings/company.js and ./js/settings/company.js differ
Files BEFORE/js/settings/deductions.js and ./js/settings/deductions.js differ
Files BEFORE/js/settings/grace.js and ./js/settings/grace.js differ
Files BEFORE/js/settings/holidays.js and ./js/settings/holidays.js differ
Files BEFORE/js/settings/index.js and ./js/settings/index.js differ
Files BEFORE/js/settings/kit.js and ./js/settings/kit.js differ
Files BEFORE/js/settings/leave-days.js and ./js/settings/leave-days.js differ
Files BEFORE/js/settings/leave-window.js and ./js/settings/leave-window.js differ
Files BEFORE/js/settings/leave.js and ./js/settings/leave.js differ
Files BEFORE/js/settings/overtime.js and ./js/settings/overtime.js differ
Files BEFORE/js/settings/permission-types.js and ./js/settings/permission-types.js differ
Files BEFORE/js/settings/places.js and ./js/settings/places.js differ
Files BEFORE/js/settings/punch.js and ./js/settings/punch.js differ
Files BEFORE/js/settings/request-kinds.js and ./js/settings/request-kinds.js differ
Files BEFORE/js/settings/visibility.js and ./js/settings/visibility.js differ
Files BEFORE/js/state.js and ./js/state.js differ
Files BEFORE/js/tabs.js and ./js/tabs.js differ
Files BEFORE/package.json and ./package.json differ
Only in .: stylelint.config.mjs
Files BEFORE/styles/base.css and ./styles/base.css differ
Files BEFORE/styles/components.css and ./styles/components.css differ
Files BEFORE/styles/layout.css and ./styles/layout.css differ
Files BEFORE/styles/tokens.css and ./styles/tokens.css differ
Only in ./styles: utilities.css
Only in ./tests: employee-form-data.test.mjs
Files BEFORE/tests/export.test.mjs and ./tests/export.test.mjs differ
Files BEFORE/tests/helpers.test.mjs and ./tests/helpers.test.mjs differ
Files BEFORE/tests/kind-names.test.mjs and ./tests/kind-names.test.mjs differ
Only in ./tests: leave-labels.test.mjs
Only in ./tests: review-attendance-data.test.mjs
Only in ./tests: tokens.test.mjs
Files BEFORE/tests/ui/behavior.mjs and ./tests/ui/behavior.mjs differ
Only in ./tests/ui: confirm.mjs
Files BEFORE/tests/ui/layout.mjs and ./tests/ui/layout.mjs differ
Files BEFORE/tests/ui/scenario-v12.mjs and ./tests/ui/scenario-v12.mjs differ
```

## Decisions, and what each costs if wrong
- R1 Audit diffs reported to Omar before code: app classes 265 (not 214), rgba 48, raw buttons 68; dead app classes only brand-bar, gate-stack (org/w3 come from an SVG URL; ot-* are dynamic); app window.confirm x2 and panel undefined 11 / unused 7 brought into scope (DoD says zero) — cost: a bit more work.
- R2 WS4 toast rule applies to panel toast() calls; one form = «تم/تمت + مصدر». App banners are multi-sentence notices, not toasts: left as they are — cost: app banners keep «أُلغي الطلب.» style.
- R3 'اليوم يوم عمل عادي' -> 'تم اعتماد اليوم يوم عمل عادي' (to fit the one form) — cost: one toast wording.
- R4 Multi-sentence empty states lose only the final full stop — cost: none.
- R5 Shared = vocabulary, tiers, type ramp, space grid, z layers, motion; brand colours and radius values stay per product (no redesign) — cost: radius-sm means 10 px in the app and 12 px in the panel.
- R6 Off-scale values snap to the nearest step; ties round down (panel 1.25rem -> lg 18, 18px -> 16) — cost: a few headings 2px smaller.
- R7 Panel breakpoint 860 merged into 1000 (top bar wraps from 1000 px down) — cost: 861-1000 px top bar on two rows.
- R8 Panel muted text #64748B -> #60708A: table heads were 4.34:1 (fails AA) — cost: secondary text slightly darker.
- R9 Panel dark theme follows the computer (prefers-color-scheme) or data-theme on <html>; no switch UI added (brief: tokens only) — cost: no in-panel toggle yet.
- R10 Panel --primary split by role: colour -> --color-accent-text, outline -> --color-focus, fills -> --color-accent (same light values) — cost: none in light.
- R11 Shared selector lists for a common base (.card, .group / .punch, .fab / .type-ico, .mini-avatar) are allowed; overrides are folded — cost: a few selectors appear in two rules (base + own).
- R12 BEM keeps compound selectors (.btn.btn--primary) so specificity is unchanged — cost: slightly longer selectors.
- R13 Classes with styles stay classes (forgot-in, setup-nudge); hook-only classes with no reader were deleted (none was used by JS or tests) — cost: none.
- R14 stylelint 17.16.0 (18.0.0 is one week old); spacing rule covers margin/padding/gap, not inset offsets of decorations — cost: offsets like the dial's -96px stay literal.
- R15 Balance bar: SVG with width attributes instead of inline style — cost: none (pixel-identical).
- R16 Panel menu position (core/ui.js list.style.left/top/minWidth) stays: runtime geometry computed per open, not a static style — cost: 3 inline style writes remain.
- R17 Before/after shots of the panel must be taken at the same clock (fake data depends on now); final evidence re-shoots both back to back.
- R18 Button default type is "button"; a typeless raw button inside a <form> got type="submit" explicitly (one place needed none) — cost: none.
- R19 Buttons that are not .btn (tab, seg__btn, quick__btn, punch, fab, logo-btn, wheels rows, password eye, switch) stay raw: they are their own components, not Button variants — cost: raw <button> count stays above zero (the brief targets the .btn ones).
- R20 Cancel dialogs: «تراجع» first (gets focus), confirm red; text from the old window.confirm — cost: one wording («تراجع») added.
- R21 useAttendance imports the ProfileInfo type from screens/Profile (type only) — cost: a type-level dependency from hooks to a screen.
- R22 Raw sb.rpc kept where the caller reads the error to detect a missing database function (isMissingFunction) — rpc() throws, which would turn "not applied yet" into an error — cost: ~22 raw calls remain in 10 files.
- R23 places add error now inline (form), with a new behaviour test — cost: one more test; message moves from toast to under the field.
- R24 confirmDialog focuses «إلغاء» first; Esc = no — cost: one more key press for a confirm.
