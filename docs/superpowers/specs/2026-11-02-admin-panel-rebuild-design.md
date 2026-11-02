# Admin panel rebuild — design

Date: 2026-11-02 · Status: draft, waiting for review · Path: architectural (restructures the whole panel; no database change in this phase)
Source reviewed: `waqti_admin_11.zip` (`index.html` 159 lines, `app.js` 2,327, `styles.css` 253, `export.js`, `employee_import.js`, `vendor/`).

## 1. What Omar asked, and what "done" means

> "Rebuild the admin panel UI. Stay close to the current design, but improve how the elements are laid out. There must be no distortion at all. Reorder the categories: everything about the employee (add, edit, …) in its own tab, the settings in their own window, and so on, in a logical and comfortable layout. Add a grace period for late arrival and early leave for each employee separately."

Decisions made with Omar in this conversation:

- Way **A**: same stack (plain HTML, CSS, JS, no build step). The code is split into small files by area.
- Tabs for daily work, one **Settings window** for everything about the company.
- **The grace period is parked** (Omar: "skip this task for now"). See section 9.

Success criteria:

1. Every feature of version 11 still works, in a place that matches its meaning (section 3 maps every control).
2. No distortion: at 1440, 1024 and 390 px wide, on every tab and every settings pane, nothing overflows the page sideways, nothing overlaps, long Arabic and English text is cut with "…" and a tooltip (section 7 proves it with a script, not by eye).
3. The look is still the same family: teal `#004357`, IBM Plex Sans Arabic, white cards on a light page.
4. The panel keeps running the same way it does now: a folder served over http (Live Server or `python -m http.server`). No Node, no build.

## 2. Out of scope

- The grace period for late arrival / early leave (parked, section 9).
- Dark mode for the panel (colors become tokens, so it is easy later).
- Any database or Edge Function change. The panel uses only the functions it uses today, plus the two Part B functions (section 6).
- New reports, new filters beyond the two in the employees tab, changes to Excel export content.

## 3. What is wrong today (found in the code)

| Problem | Where | Effect |
|---|---|---|
| `td.actions { display:flex }` | `styles.css` line 165 | A table cell that is not `display:table-cell` makes the browser create anonymous cells. The "actions" column and the row borders drift out of line. This is the main "distortion". |
| 11 buttons in one toolbar | `index.html` lines 56-70 | They wrap in uneven rows. Company settings, approval rules, imports and employee work are mixed. |
| Table `min-width: 860px`, fixed 7 columns | `styles.css` 160 | Under about 900 px the whole table scrolls sideways. |
| One 335-line employee form with 6 fieldsets in one scroll | `openEmployeeForm` | Hard to find a field; the save button is far away. |
| `app.js` is one 2,327-line closure | | Hard to change one area without touching others. |
| Settings are 8 separate dialogs reached from 3 different tabs | | Nobody can guess where "overtime limits" is. |

## 4. Layout

```
┌────────────────────────────────────────────────────────────────────────────┐
│ وقتي   الموظفون │ الحضور │ الطلبات │ العمل الإضافي          ⚙ الإعدادات   user ▾ │  top bar
├────────────────────────────────────────────────────────────────────────────┤
│ [ 24 إجمالي ] [ 22 فعّال ] [ 2 بحاجة لنطاق ]                                  │  stats
│ [🔍 بحث…] [الإدارة ▾] [الحالة ▾] [⟳]        [أدوات ▾]  [+ إضافة موظف]          │  toolbar
│ ┌ الكود │ الموظف │ الإدارة / المكان │ الحالة │ النطاق الجغرافي │  ⋯ ┐          │  table
└────────────────────────────────────────────────────────────────────────────┘
```

- Top bar: brand, the four tabs, then at the end the **⚙ الإعدادات** button and the user menu (e-mail + sign out). The tabs are real links with `aria-current`.
- Page: `max-width: 1280px`, gutter 24 px (14 px under 600 px).
- One frame for every tab: *page title row → filters/toolbar card → summary line → table card → pager*. The four tabs share it, so nothing jumps when you switch.

### 4.1 Employees tab

- **Toolbar:** search, department filter, status filter (فعّال / معطّل / الكل), refresh icon. At the end: **أدوات ▾** and the primary **+ إضافة موظف**. Filters work on the list already loaded (no new server call).
- **أدوات ▾** menu: قالب Excel · استيراد من Excel · المدراء المباشرون (the bulk dialog).
- **Row:** clicking the employee name opens «تعديل». The last cell has a **⋯** menu: تعديل · النطاق الجغرافي · المدير المباشر · كلمة مرور جديدة (not on your own row). The cell has a wrapper `div`; the `td` stays a table cell.
- Columns: الكود · الموظف (name + job title + "بيانات ناقصة" badge) · الإدارة / المكان · الحالة · النطاق · ⋯. The e-mail moves into the employee cell as a small line (it was a full column of long text).
- **Under 720 px** each row becomes a card (`td[data-label]` + CSS), no sideways scroll.

### 4.2 Employee form (add / edit)

Same fields, same server calls. Instead of one long scroll, the wide dialog has a small tab bar: **الأساسية · الدوام · الراتب · الإجازات · الحساب والبصمة** (the last one holds punch-time overrides and the registered device, edit mode only). One `<form>`; the tab only shows or hides a pane. *This was not in the design Omar approved in chat; it follows from "no long, confusing forms". Tell me if you prefer the single scroll.*
Rule to avoid a classic bug: hidden panes still hold `required` inputs, so on submit the code runs `checkValidity()` itself, switches to the first pane with an invalid field, and shows the message there.

### 4.3 Attendance, Requests, Overtime tabs

Same frame as 4.1: a filter card (grid, 170 px minimum columns, as today), a summary line, the table, the pager. Attendance has one action group at the end of the filter card: **تصدير Excel** and **تقرير تفصيلي Excel**. "حدود العمل الإضافي" leaves the Overtime tab and goes to Settings.

## 5. Settings window

The ⚙ button opens one `<dialog>`: `width: min(1040px, 96vw)`, `height: min(720px, 90vh)`. In RTL the side menu is on the right (220 px), the pane on the left. Under 720 px the side menu becomes a select at the top.

| Group | Pane | Content (moved from) | Server functions (unchanged) |
|---|---|---|---|
| عام | **الشركة** | company name (`openCompanyNameDialog`) | `admin_get_company_settings`, `admin_set_company_name` |
| عام | **أماكن العمل والنطاقات** | list of places + geofence map (`openLocationsDialog`, `openLocationGeofenceDialog`) | `admin_list_work_locations`, `admin_add_work_location`, `admin_set_location_geofence` |
| الدوام | **الدوام والبصمة** | fingerprint policy, punch windows (`openPunchSettingsDialog`) | `admin_get_punch_settings`, `admin_set_punch_settings` |
| الدوام | **الإجازات** | annual leave age rule (`openPolicyDialog`) | `admin_get_leave_policy`, `admin_set_leave_policy` |
| الدوام | **العمل الإضافي** | daily and monthly limits (`openOvertimeLimitsDialog`) | `admin_get_overtime_settings`, `admin_set_overtime_settings` |
| الموافقات والبيانات | **مسار الموافقات** | approval paths (`openChainsDialog`) | `admin_get_approval_chains`, `admin_set_approval_chain` |
| الموافقات والبيانات | **أنواع الأذونات** | permission types list + form (`openPermissionTypesDialog`) | `admin_list_permission_types`, `admin_save_permission_type` |
| الموافقات والبيانات | **ظهور بيانات الموظف** | **new** (Part B, section 6) | `admin_get_profile_visibility`, `admin_set_profile_visibility` |

Behavior:

- Each pane loads when opened (loading, error with retry, content) and has **its own** save button. Save text and error messages are the ones used today.
- **Unsaved changes:** if a pane has edits and the user clicks another pane or closes the window, ask "لديك تغييرات غير محفوظة. تجاهلها؟".
- The window can open straight on a pane (`openSettings('leave')`), so a hint like "ضبط قاعدة الإجازة" in the employee form can link to it.
- Reserved place: a **«فترة السماح»** entry will go under الدوام when that feature is built.
- The direct-manager **assignment** (who manages whom) stays in the employees tab (it is employee data). The approval **rules** are in Settings (they are company rules).

## 6. Part B: «ظهور بيانات الموظف» pane

Defined in `2026-11-02-profile-summary-visibility-design.md` (sections 3, 4 and 6). In the panel:

- Loads `admin_get_profile_visibility()`; shows the 11 items in 5 groups (الوظيفة · الدوام · الإجازات · الراتب · شخصي), one switch each.
- Buttons: إظهار الكل · إخفاء الكل · الإعداد الافتراضي · حفظ. Save sends all 11 keys to `admin_set_profile_visibility`, then shows "تم الحفظ — يسري على جميع الموظفين عند فتح صفحة حسابي".
- Note under the title: "هذا الإعداد لكل الشركة، ولا يؤثر على ما تراه أنت في لوحة التحكم." and the age-inference warning from the Part B risks.
- **Rollout safety:** if the functions do not exist yet (migration not applied), the pane shows "غير متاح بعد: يلزم تحديث قاعدة البيانات" and the rest of the panel is not affected. So the panel can ship before or after the migration.

## 7. Architecture and files

Plain ES modules (`<script type="module">`; CSP `script-src 'self'` already allows them). The panel already has to be served over http for the map, so modules add no new requirement. `export.js` and `employee_import.js` stay as they are (classic scripts, `window.WaqtiExport` / `window.WaqtiImport`).

```
waqti-admin/
  index.html            shell: login, top bar, four tab containers, settings dialog host, toasts
  config.js             unchanged
  export.js, employee_import.js, vendor/   unchanged
  styles/tokens.css     colors, spacing, radius, sizes (same teal; one scale)
  styles/base.css       reset, typography, text-overflow utilities (as today)
  styles/components.css buttons, inputs, badges, cards, table, menu, tabs, dialog, toasts
  styles/layout.css     top bar, page frame, toolbar, settings window, responsive rules
  js/main.js            start: session → enter → tabs
  js/core/dom.js        $, h, field, checkbox, trunc
  js/core/ui.js         toast, modal, confirm, menu(), tabs(), sidenav()
  js/core/api.js        supabase client, invokeFunction, rpc helper
  js/core/errors.js     ERRORS table + errText (unchanged texts)
  js/core/state.js      employees, workLocations, leavePolicy, managers, loaders
  js/auth.js            login, forced password change, sign out
  js/employees.js       tab, table, tools menu, row menu, reset-password, credentials
  js/employee-form.js   add/edit dialog with section tabs
  js/geofence.js        map picker, employee geofence dialog
  js/managers.js        direct-manager bulk dialog
  js/attendance.js      log tab, export dialog, detailed report
  js/requests.js        requests tab, decision dialog
  js/overtime.js        overtime tab
  js/settings/index.js  window shell: side menu, pane registry, unsaved guard
  js/settings/{company,places,punch,leave,overtime,approvals,permission-types,visibility}.js
  tests/                section 8
```

Rules:

- **Move, don't rewrite.** The body of each existing dialog (fields, validation, RPC calls, messages) is kept; only its container changes from `modal(...)` to a pane. This is the main protection against losing a feature.
- A pane module exports `{ id, title, group, render(container) }` and `render` returns `{ isDirty() }`.
- `ui.menu()` is one small accessible dropdown (button with `aria-haspopup`, `role="menu"`, closes on Esc and outside click, arrow keys). It serves **أدوات ▾**, **⋯** and the user menu.
- All dynamic text is still inserted as text (`h()` never uses `innerHTML`). No new libraries.

### 7.1 Visual rules (the "no distortion" contract)

- Tokens: colors as today (`--primary #004357`, `--primary-2 #0D5C75`, `--success #059669`, `--warning #D97706`, `--error #DC2626`; they already match the employee app's meaning: green = in / success, red = out / error, amber = waiting). Spacing 4 · 8 · 12 · 16 · 24 · 32. Radius 12 (controls) and 16 (cards, dialogs). **One control height: 40 px** (buttons and inputs). Button styles: primary, normal, ghost, danger.
- Never `display:flex/grid` on `td`/`th`. Put a wrapper inside the cell.
- Every flex or grid child that holds text gets `min-width:0`; grids use `minmax(0, 1fr)`.
- Text in cells goes through `trunc()` (ellipsis + tooltip). Columns have width classes (`.col-code`, `.col-status`, `.col-actions`) so they do not jump between pages.
- Dialogs: header and footer fixed, body scrolls (`max-height`). The save button of a form is always visible.
- The toolbar wraps by **groups** (filters | tools | primary), never button by button.

## 8. Verification

1. **Feature inventory check** (script): collect every `sb.rpc('…')`, `functions.invoke('…')` and `#id` handler in version 11, and require the same RPC names to be reachable in the new code (28 RPCs and 3 Edge Functions today, plus the 2 Part B functions). A missing one fails.
2. **Layout test** (Playwright, already installed in the workspace): the panel runs with a **fake Supabase client** (canned data: 24 employees including a 90-character name, a 60-character e-mail, English and Arabic mixed, an inactive one, one without a geofence). For each of the 4 tabs, the settings window with each of the 8 panes, the employee form with each of its 5 section tabs, at **1440, 1024 and 390 px**, the test fails if:
   - `document.documentElement.scrollWidth > innerWidth`;
   - any element outside a `.table-card` scroller extends beyond the viewport;
   - two sibling controls in a toolbar overlap (bounding boxes);
   - a dialog is taller than the viewport or its footer is not visible.
   It also saves screenshots. I run it first on version 11 (the "before" evidence for the distortion) and then on the new panel.
3. **Unit tests** (`node --test`, no install): `errText` mapping, `readMinutes`, hours↔minutes conversion, the status/department filters, the card-label builder, the unsaved-changes guard.
4. **Manual smoke test by Omar** on the real Supabase project (sign in, add and edit an employee, a geofence, an approval path, an export). I cannot sign in to his project, so this is his step. I list the exact click path.

## 9. Parked: grace period (فترة السماح)

Not built now. What I learned, so the next round starts fast:

- The system has **no "late" or "early leave" status** today, in the database or in the panel. There are only «تبرير تأخير» permission requests and the punch windows (which control *when a punch is allowed*, not *when it counts as late*).
- A grace period needs: a definition of late / early per shift day, one company default plus a per-employee value (the same shape as the punch windows: `companies` columns, nullable `employees` columns, one admin function each), and a place that shows the result (attendance log and Excel marks; optionally an employee warning and monthly totals). Omar skipped the question about which of these he wants.
- Its UI slots are ready: a Settings pane «فترة السماح» and a section in the employee form's «الدوام» tab.

## 10. Delivery and rollout

- Output: the new `waqti-admin/` folder, delivered as **`waqti_admin_12.zip`**, plus an updated `README.md` (new structure, where each control lives, how to run, how to test).
- **Decided (Omar, 2026-11-02): the panel stays outside the repo.** He downloads the zip and runs it on his own computer. It is not committed to GitHub and not put on GitHub Pages. Only the specs and plans about it live in `docs/superpowers/`.
  - Because it is not versioned in git, every delivery has a version number in the zip name (`waqti_admin_12.zip`) and a short changelog at the top of its `README.md`. Omar keeps the old folder as the way back.
  - The `tests/` folder travels inside the zip for later work, but the panel runs without it. Omar does not need Node or Playwright; I run the tests here before sending the zip.
- Nothing touches production data. The panel works with the current database. The Part B pane waits for its migration (which needs Omar's yes).
- Order: build and test → Omar's smoke test → he replaces his folder with version 12. Version 11 stays as the way back (just keep the old folder).

## 11. Risks

- **Big change, one release.** Mitigation: "move, don't rewrite", the RPC inventory check, and keeping version 11 as the fallback.
- **Hidden `required` inputs in the tabbed employee form** can block saving with a silent browser error. Mitigation: own `checkValidity()` handling (section 4.2) and a unit test.
- **`<dialog>` and focus in older browsers.** The panel already uses `<dialog>` today, so no new risk.
- **File count grows from 5 to about 30.** Every file has one job and a name that says it; this is the price of removing the 2,300-line closure.
- **The fake-Supabase test proves layout, not server behavior.** Server behavior is covered by Omar's smoke test and by the database tests that already exist.
