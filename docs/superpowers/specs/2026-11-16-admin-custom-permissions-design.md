# Custom permissions for system admins (database phase 28 + admin panel 12.27)

Date: 2026-11-16. Status: **built and tested locally** after Omar's go-ahead («تمام قم بتعديل الدوال، ولكن دون الاضرار بأي شيئ آخر»). Nothing here is applied to production, pushed or deployed. This file was corrected after the build (see ruling 6 and the groups table): the first draft cut the groups differently.
Branch: `feature/punch-mode-company-roles`. The panel folder (`/home/claude/waqti-admin`) is not a git repo and is never deployed by Claude (Omar installs the zip himself).

## 1. What was asked
Omar, 2026-11-16: «قم بإضافة صلاحيات مختلفة بين مسؤولي النظام يتم تحديدها من قبل مدير النظام … دون المساس بأي شيء آخر». Then: **permissions only; the "add company" part is skipped** (no companies window, no company-wide isolation sweep in this piece of work).
Answered by Omar when asked what "different permissions" means: **custom permissions per admin**, chosen by the system manager (the owner, `company_admin`), not only the three fixed levels of phase 26.

Words used here: *owner* = «مدير النظام» (`company_members.role = 'company_admin'`); *limited level* = hr_admin / supervisor / viewer (phase 26); *custom admin* = the new `custom_admin` level; *group* = a named set of admin functions.

## 2. Where we start (verified 2026-11-16)
- Phase 26 (fixed levels, allow-list `private.admin_role_rpcs`, gate `public.require_company_admin()`) is built and tested locally but **NOT applied to production** (`admin_list_admin_roles` does not exist there). So **phase 28 cannot be applied before phase 26**.
- The gate looks at the outermost `admin_*` frame of the call stack and at the allow-list of the caller's level; default deny. 81 `admin_*` functions exist; 46 are listed for some limited level; 35 are owner-only (settings, payroll/deduction, holidays, delete employee, admin management, `admin_edit_punch` of phase 27, …).
- The panel already hides every button with `canDo(rpc)`, fed by `my_admin_context().permissions`. Only phase 26's file mentions the limited role names, so the places to extend are few (section 4).

## 3. Approach (chosen: named groups, additive on a fixed read-only base)
Rejected: per-function ticks (about 50 technical names, unusable); fully custom roles per company (bigger than the need).

### Rulings (each one can be reversed by Omar; cost if wrong in brackets)
1. **Every custom admin always has the viewer set** (read-only lists of employees, attendance, requests, overtime, leave days, settings reads; no salaries). Groups only **add** to it. [Cannot make an admin who sees only requests and not attendance. The panel was only ever tested with the viewer shape as its floor, so this keeps every screen working. Lifting it later is a catalogue change plus panel tests.]
2. **Groups re-slice what phase 26 already allows to an HR admin, plus `admin_edit_punch` (phase 27).** A custom admin never gets a power the HR admin level cannot already have, except editing a movement's time. [New powers such as holidays or company settings stay owner-only; opening one later = one insert into the catalogue.]
3. **Salary visibility follows the employee file.** `admin_get_employee_profile` returns the salary, so the group that opens the file shows it. [Hiding salary from a file editor needs a change inside that function: out of scope.]
4. **Never grantable (owner-only forever):** `admin_list_admins`, `admin_add_admin`, `admin_remove_admin`, `admin_list_admin_roles`, `admin_set_admin_role`, `admin_list_admin_grants`, `admin_set_admin_grants`, `admin_company_id`, `admin_delete_employee`, `admin_set_company_name`, `admin_set_company_settings`, and everything else not in a group. A database test asserts that none of them is in any group.
5. A limited or custom admin still cannot change an account that holds any admin level (`private.assert_not_admin_target`, unchanged), still signs in with a password only, and still cannot be deleted before the level is removed.
6. **Groups follow screens, not database topics (changed during the build).** The first draft had a group «الدوام والنطاق والأجهزة» (grace, punch windows, geofence, devices). A survey of which functions each panel screen calls showed that the **employee form** reads and writes the grace period, the punch windows and the device binding, so an admin who could open the form with the `employees` group alone would have had a form half refused. The groups were re-cut so that **each group alone gives working screens**: the employee form's functions all moved into `employees`; `workplace` became the geofence and location policy only. The panel's strict fake (it refuses any `admin_*` call outside the permission list, like the gate) now opens and saves the employee form with the `employees` group alone. Two functions of the catalogue (`admin_update_employee`, `admin_set_employee_location_policy`) are not called by this panel at all; they are in the groups because phase 26 already gave them to the HR level.

### The groups (v1)
| key | Arabic name (panel) | functions it adds on top of the base |
|---|---|---|
| `decisions` | قرارات الطلبات والإجازات | `admin_review_queue`, `admin_decide_request`, `admin_decide_leave_day`, `admin_resolve_leave_conflict`, `admin_resolve_review`, `admin_dismiss_missing_checkin`, `admin_get_leave_years`, `admin_get_employee_kind_days`, `admin_get_employee_grace` (9) |
| `employees` | ملفات الموظفين (تشمل الرواتب) | everything the employee form calls: `admin_get_employee_profile`, `admin_save_employee_profile`, `admin_update_employee`, `admin_set_employee_manager`, `admin_set_leave_year`, `admin_set_employee_kind_days`, `admin_set_employee_grace`, `admin_set_employee_punch_windows`, `admin_list_device_bindings`, `admin_remove_device` + the 3 reads of `decisions` it needs (13) |
| `workplace` | النطاق الجغرافي والموقع | `admin_set_geofence`, `admin_use_location_geofence`, `admin_set_employee_location_policy` (3) |
| `punches` | الحركات اليدوية | `admin_add_punch`, `admin_edit_punch` (2) |
A function may be in several groups (primary key is `(group_key, rpc)`), so a write never loses the read it needs. Exact membership is the catalogue in the migration; this table is its design (9 + 13 + 3 + 2 rows; the panel's strict fake carries a copy that was compared with the database catalogue once, see the hand-off).

## 4. Database (migration `20261116120000_phase28_admin_custom_permissions.sql` + `_ROLLBACK.sql`, delivered separately)
Guard first: phases 26 and 27 present, else a clear message and nothing kept.
- `company_members_role_check` gets the value `custom_admin`.
- `private.admin_groups (group_key pk)`, `private.admin_group_rpcs (group_key fk, rpc, pk both)`: the catalogue, data only.
- `private.admin_grants (company_id, user_id, group_key fk, granted_by, granted_at, pk (user_id, group_key))`. Not readable by `anon`/`authenticated`.
- `private.limited_admin()` also returns `custom_admin`.
- New helpers `private.admin_may_call(user, company, role, rpc)` and `private.admin_permissions_of(user, company, role)`: for the 3 levels they read `admin_role_rpcs` (as today); for `custom_admin` = viewer rows ∪ rows of his groups **in his own company**.
- `public.require_company_admin()` is replaced with phase 26's body where the single `exists (… admin_role_rpcs …)` becomes `private.admin_may_call(...)`. The owner path and the `must_change_password` check are untouched.
- `public.my_admin_context()`: `permissions` for `custom_admin` comes from `admin_permissions_of`; `admin_role` returns `custom_admin`; `is_panel_user` includes him.
- `public.admin_list_admin_grants()` → `(user_id, group_key)` of the caller's company. Owner only.
- `public.admin_set_admin_grants(p_employee_id uuid, p_groups text[])` → jsonb. Owner only. Under the same advisory lock as `admin_set_admin_role` (`waqti.admins:<company>`). Refuses: self (`cannot_change_self`), another company's or unknown employee (`not_found`), inactive employee, empty list (`no_groups`), unknown key (`invalid_group`), same role and same set (`no_change`), demoting the last working owner (`last_admin`). Sets the role to `custom_admin` (also for an employee or an owner that is changing level) and replaces his rows. Audit: `admin.role_changed` when the role changes and `admin.grants_changed` (from, to).
- `public.admin_set_admin_role(...)`: when the target leaves `custom_admin` his grant rows are deleted (no stale rights); it still refuses to set `custom_admin` (only `admin_set_admin_grants` can).
- `public.admin_delete_employee(...)`: the "holds an admin level" check becomes `role <> 'employee'` (it listed the three names).
- Nothing else is changed. Grants of a user whose role is not `custom_admin`, or whose company differs from the grant's, are inert (the gate joins on both).

## 5. Panel (12.27, zip for local install)
- `lib/roles.js`: `custom_admin` is a level (label «مخصص», hint), placed before the owner in the list.
- New `lib/grants.js` (pure, unit-tested): the group catalogue (Arabic names and hints), selection check, texts.
- New `settings/admin-grants.js`: a dialog with the base shown as always on and locked («الاطلاع العام») and one tick per group, with its hint. Saving asks first, then calls `admin_set_admin_grants`.
- `settings/admins.js`: choosing «مخصص» (in a row or in the add form) opens the dialog; closing it without saving puts the old level back. A custom row shows its group names and a «تعديل الصلاحيات» button. The pane reads `admin_list_admin_grants`; if that function is missing (phase 28 not applied) the choice «مخصص» is hidden and the pane is exactly today's (tested).
- A custom admin signs in like the other levels (`my_admin_context().admin_role = 'custom_admin'`). **An older panel (12.26) does not know that level and refuses to open for a custom admin** («هذا الحساب ليس حساب مدير»); owners and the other levels are not affected. So install panel 12.27 before the first custom admin is created.
- Nothing else in the panel changes; every screen keeps using `canDo`.

## 6. Tests (red first, then green)
- **Database `tests/phase28_admin_custom_permissions_tests.sql`:** privileges (anon, employee, hr_admin, owner of another company refused); catalogue invariants (section 3 ruling 4; every function name in the catalogue exists); set / replace / change level clears grants; the gate per group (allowed and refused calls, the base always on, an unlisted function refused); stale and cross-company grant rows inert; owner of company B cannot grant in company A and a custom admin of A reaches nothing of B; `must_change_password` still blocks; cannot touch admin accounts; deletion refused; password-only sign-in; `my_admin_context` shape; audit rows; refused calls write nothing.
- **Mutation check (database):** deliberate breaks of the gate (grants ignored, company not matched, base dropped), of the set function (no company scope, no clearing, no last-owner check) and of the catalogue (a forbidden function inside a group) must each be caught.
- **Regression:** the whole database suite (38 files today; the one known clock failure is phase 15) must give the same results as before plus the new file; rollback proof as in phase 27 (database built with 28 then rolled back equals a database without 28).
- **Panel:** `npm test`, behaviour test with a **strict fake** that refuses any function not in the permission list (like the database does), run **once per group alone**, for the base alone and for all groups together (this is what proves each screen works with a single group), layout test for the new pane and dialog at 6 widths, light and dark, stylelint, mutation of the panel's own code (15 deliberate breaks).

## 7. Order of application (each step needs Omar's own word)
phase 26 migration → phase 28 migration → panel 12.27 (installed by Omar from the zip). The panel is safe before 28 (it hides «مخصص»). Production migrations only after «نعم»; push only after «ارفع»; the employee app is not touched by this work.

## 8. Known limits and risks
1. `require_company_admin` is the gate of every admin function. Replacing it is the riskiest line of the work; the whole suite, the mutation checks and the rollback proof are the answer.
2. Combinations are tested group by group, not every one of the 2^4 combinations (a group only adds functions, and the panel gates by function, so a combination is the union of what each group shows).
3. No "hide attendance from this admin" (ruling 1) and no "hide salary from a file editor" (ruling 3).
4. A new `admin_*` function is owner-only until someone inserts it into a group (default deny stays).
5. No company-wide isolation sweep over all tables was requested; only the isolation of the new grants is tested.
