# Phase 28 — custom permissions for system admins («مخصص»): run it locally, and how to apply it later

One migration and the admin panel **12.27.0**. **Nothing of phase 28 is applied to production, deployed or pushed.** Branch: `feature/punch-mode-company-roles` (local commits only; the panel folder is not a git repo, so the panel is delivered as a zip that Omar installs himself).

| | Migration (+ rollback `…_ROLLBACK.sql`) | Needs before it | Panel | App |
|---|---|---|---|---|
| **28 — custom admin permissions** | `supabase/migrations/20261116120000_phase28_admin_custom_permissions.sql` | **phase 26** (admin levels) and **phase 27** (`admin_edit_punch`). The file stops with a clear message, and keeps nothing, if either is missing | the new level «مخصص» and a groups dialog in Settings ← مديرو النظام | none |

**Production today lacks phases 25 and 26** (verified 2026-11-16: `admin_list_admin_roles` does not exist there), so phase 28 cannot be applied before phase 26. Order: 26 → 28 → panel 12.27 (see §3).

Request from Omar (2026-11-16): two things (a companies window with company-wide isolation, and different permissions between system admins chosen by the system manager). Then: «قم بإضافة الصلاحيات فقط تخطى موضوع الشركات» — **only the permissions were built; the companies part was skipped on purpose.** When asked what «صلاحيات مختلفة» means he chose **custom permissions per admin, chosen by the system manager** (not only the three fixed levels of phase 26). Design: `docs/superpowers/specs/2026-11-16-admin-custom-permissions-design.md`.

## What it does, in plain words
In Settings ← مديرو النظام the system manager (مدير النظام) can give a person the level **«مخصص»** and tick what he may do. A custom admin **always** has «الاطلاع العام» (the read-only lists the viewer level has: employees, attendance, requests, overtime, leave days, settings reads; **no salaries**). On top of that, the owner ticks any of four groups:

| Group (key) | Panel name | What it opens | Functions |
|---|---|---|---|
| `decisions` | قرارات الطلبات والإجازات | decide requests and leave days, resolve review items and leave conflicts, dismiss a missing check-in | 9 |
| `employees` | ملفات الموظفين (تشمل الرواتب) | the whole employee form: profile **with salary**, manager, leave year, kind days, grace, punch windows, devices | 13 |
| `workplace` | النطاق الجغرافي والموقع | an employee's geofence, "use the place's geofence", location policy | 3 |
| `punches` | الحركات اليدوية | add a movement by hand and edit the time of a movement (phase 27) | 2 |

A group never gives a power the HR level (phase 26) cannot already have, except editing a movement's time. **Never grantable, whatever is ticked** (owner only): managing admins and their levels (`admin_list_admins`, `admin_add_admin`, `admin_remove_admin`, `admin_list_admin_roles`, `admin_set_admin_role`, `admin_list_admin_grants`, `admin_set_admin_grants`), `admin_company_id`, deleting an employee, company name and company settings, and everything not in a group (payroll and deduction settings, holidays, leave policy, request kinds, and so on). A custom admin also cannot change the account of anyone who holds an admin level, signs in with a password only (no fingerprint), and must change his temporary password first — the same protections as the other limited levels.

Leaving the custom level (to another level, or removed) deletes his groups, so no stale right is left behind.

## What the migration contains
Guard (phases 26 and 27 present) first, then, in one transaction:
- `company_members_role_check` accepts `custom_admin`.
- Three tables in schema `private` (not readable by `anon` or `authenticated`): `admin_groups` (the 4 keys), `admin_group_rpcs` (the catalogue, primary key `(group_key, rpc)`), `admin_grants (company_id, user_id, group_key, granted_by, granted_at)`; grants cascade when the company or the employee is deleted.
- `private.admin_may_call(user, company, role, rpc)` and `private.admin_permissions_of(user, company, role)`: for the three fixed levels they read the phase 26 allow-list exactly as before; for `custom_admin` the answer is the viewer rows plus the rows of his groups **in his own company** (a grant row of another company, or of a person who is no longer custom, is inert).
- `private.limited_admin()` also returns `custom_admin`.
- `public.require_company_admin()` — the gate of every admin function — is replaced with phase 26's text where its single allow-list check became `private.admin_may_call(...)`. The owner path and the `must_change_password` check are untouched.
- `public.my_admin_context()` answers `admin_role = 'custom_admin'` and the permission list.
- New, owner only: `public.admin_list_admin_grants()` and `public.admin_set_admin_grants(p_employee_id uuid, p_groups text[]) returns jsonb`. The second one gives the person the custom level when he did not have it, replaces his groups as a whole, works under the same advisory lock as `admin_set_admin_role` (`waqti.admins:<company>`), and writes the audit rows `admin.role_changed` (when the level changes) and `admin.grants_changed` (from, to). Its refusals, none of which writes anything: `forbidden`, `cannot_change_self`, `not_found` (also for another company's employee), `employee_inactive`, `no_groups`, `invalid_group`, `no_change`, `last_admin`.
- Two existing functions are patched in place by text (`pg_get_functiondef`): `admin_set_admin_role` deletes the grants of a person who leaves the custom level (it still refuses to *set* `custom_admin`: only `admin_set_admin_grants` can), and `admin_delete_employee` treats `custom_admin` as an admin level that must be removed before deleting.
Nothing else in the database changes.

## 1. Run the database test (local only)
```bash
cd supabase
PGDATABASE=postgres TESTS=tests/phase28_admin_custom_permissions_tests.sql bash local/test-db.sh    # only phase 28 (139 assertions)
PGDATABASE=postgres bash local/test-db.sh                                                           # every file, each on a fresh database
```
Same setup as phases 24 to 27 (Postgres 16 + PostGIS, libfaketime; **start the server with `PGHOST` and `PGPORT` in its own environment**, the phase 21 test needs them for `dblink`). The file covers: privileges (anon, an employee, an HR admin, a custom admin and the owner of another company are refused); the catalogue (counts per group; **none of the never-grantable functions is in any group**; every function named in it exists); setting, replacing, and changing level (a person who leaves the custom level loses his grants); the gate **per group with real calls** (an allowed call goes through, a call outside the groups is `forbidden`, the base is always on, an unlisted function is refused); a sweep over every `admin_*` function of the schema (more than 80) for each group alone and for all four together, which must give exactly the viewer list plus that group's rows, and the owner-only list stays closed even with every group; the shape of `my_admin_context`; stale grant rows (the person is no longer custom) and grant rows of another company are inert; a second company cannot grant in the first and a custom admin of one reaches nothing of the other; `must_change_password` still blocks; cannot touch admin accounts; deletion refused; password-only sign-in; the audit rows; refused calls write nothing.
**Red first:** the file was run before the migration existed and failed on the missing objects; then green. **Mutation check:** 24 deliberate breaks, each caught by at least one assertion — **24 / 24**: the helper ignores the company, ignores the user, drops the viewer base, opens everything to an unknown role; the permission list without the groups; the limited-admin check without the custom level; the gate ignores grants; the context shows the base only; `admin_set_admin_grants` without company scope, keeping the old rows (no replace), without the empty-list, group, self, inactive and no-change checks, with the audit action renamed, without the level-change audit, without the owner-demotion record; the grants list without the company filter; `admin_set_admin_role` keeping the groups when a person leaves the level; `admin_delete_employee` ignoring the custom level; and three breaks of the catalogue (a forbidden function inside a group, a group that loses a read, a new power inside a group). (One earlier run showed 23 / 24: the file of one mutation was left over from before the groups were re-cut and deleted a row that no longer existed, so it changed nothing; all 24 files were deleted and regenerated, and the full check was run again.)

## 2. Other tests (last run 2026-11-16)
| What | Command | Result |
|---|---|---|
| Database, phase 28 | §1 | 139 passed, 0 failed |
| Database, whole suite | §1 | **39 files, 2000 passed, 1 failed** — the one failure is `phase15_leave_conflict_tests.sql` (clock, as before); the 38 older files give exactly their earlier results (1861 + 139 = 2000) |
| Database, rollback proof | build all migrations, apply the phase 28 rollback, compare with a database built without 28 | 858 lines identical (§4) |
| Admin panel, unit | `npm test` (panel folder) | 198 / 198 (new: `tests/grants.test.mjs`, the custom level in `tests/roles.test.mjs`, the inventory now lists 51 new functions); also 198 / 198 from the extracted zip |
| Admin panel, behaviour (fake client, Playwright) | `node tests/ui/behavior.mjs .` | 733 passed, 0 failed (732 + 1 since the wording fix; before that 3 consecutive runs 732 / 0); also 733 / 0 from the extracted zip |
| Admin panel, layout | `node tests/ui/layout.mjs --dir . --scenario levels\|v12 --scheme light\|dark --out <dir>` | levels light 96, dark 96 (30 new screens each: the custom rows, the groups dialog, its two errors, a custom admin's two screens); v12 light 366, dark 366 (run before the last wording fix, which changes no layout) — 0 with problems, 0 issues, 0 script errors in all four |
| Admin panel, CSS | `npx stylelint "styles/**/*.css"` | clean (no CSS was added) |
| Mutation check of the panel | 15 deliberate breaks of the panel's own code (custom treated as owner, level not accepted, custom sent through the role function, «مخصص» shown without phase 28, empty selection accepted, no question before saving, base not locked, edit button on every row, wrong group order, every group always sent, no warning when leaving the level, the old level not restored when the dialog is closed, groups not read, salary warning removed, the saved groups not ticked) | 15 / 15 caught (one first attempt, an unknown-key guard, was redundant code and changed nothing: the function was simplified and the mutation redone) |
| App | not touched by this phase | — |
The panel's behaviour test runs with a **strict fake client**: like the database gate it answers `forbidden` to any `admin_*` call outside the permission list of the signed-in level, and remembers it. It is run for **each group alone**, for the base alone, and for all four together, and each run must end with no refused call and no script error. The employee form is opened and saved with the `employees` group alone. The fake's copy of the catalogue and of the viewer base was compared with the real database catalogue (4 groups and 23 viewer rows, equal).

## 3. How to apply it later (needs Omar's fresh «نعم»)
**Order: 26 (and 25 if wanted) → 28 → panel 12.27.** Production lacks 25 and 26 today. The panel 12.27 is safe before 28 (it hides «مخصص» and the pane is the one of 12.26). **Install 12.27 before the first custom admin is created**: panel 12.26 does not know the level and refuses to open a custom admin's account («هذا الحساب ليس حساب مدير»); owners and the other levels are not affected. Panel = installed by Omar from the zip; a push = «ارفع».
1. Apply the migration with `apply_migration` (one call, the exact file text; check with grep that the file has no backslash). One transaction: if the guard fails, nothing is kept.
2. Compare with the local values (`md5(prosrc)` read from the local database after all migrations):

| Function | `md5(prosrc)` | secdef / volatility | settings / execute |
|---|---|---|---|
| `public.admin_list_admin_grants()` | `0a9fb79ddc97eceeca6bbc2fd03c5f15` | yes / stable | `search_path=""`; `authenticated`, `postgres`, `service_role` |
| `public.admin_set_admin_grants(uuid, text[])` | `f49da8c881ce2b41de57e06d26fc8b9c` | yes / volatile | same |
| `public.require_company_admin()` (replaced) | `6f4a2bbfb1a5b5e225221b1836a44205` | yes / stable | `postgres`, `service_role` only |
| `public.my_admin_context()` (replaced) | `06430c0808a9c878c41c614e60254584` | yes / stable | `authenticated`, `postgres`, `service_role` |
| `public.admin_set_admin_role(uuid, text)` (patched) | `4737df3bccfbde1eba05e83bc404db3f` | yes / volatile | `search_path=""`; `authenticated`, `postgres`, `service_role` |
| `public.admin_delete_employee(uuid, text)` (patched) | `098eb2a0175111c5e3815c3973b4d82a` | yes / volatile | `search_path=public`; `authenticated`, `postgres`, `service_role` |
| `private.admin_may_call(uuid, uuid, text, text)` | `5732c3b4b19d333b046bdc5cc5188281` | yes / stable | `postgres` only |
| `private.admin_permissions_of(uuid, uuid, text)` | `5261302279cb0aca158ba2bdba8ac137` | yes / stable | `postgres` only |
| `private.limited_admin()` (replaced) | `3020efdf875eeda117c1b5c145ab5141` | yes / stable | `postgres` only |

Catalogue (group, rows, `md5` of the sorted function names): `decisions` 9 `1ad6e6ab4e4ddb2e025c5dde0be5ef88` · `employees` 13 `45ae8f2153a0c3965e405d2c718b1f67` · `workplace` 3 `99a5eb925fa3ec3c77e135365a4bbf14` · `punches` 2 `ee03a666d5bf24edd85be057d7288bbb`. The three new tables are not readable by `anon` or `authenticated`. `company_members_role_check` now lists `custom_admin`.
Note: the production versions of `require_company_admin`, `my_admin_context`, `limited_admin`, `admin_set_admin_role` and `admin_delete_employee` are the ones phase 26 creates, so these fingerprints are comparable only **after** phase 26 is applied there.
3. Smoke test after applying (read-only): `select count(*) from private.admin_group_rpcs` must be 27; `has_function_privilege('anon', 'public.admin_set_admin_grants(uuid, text[])', 'execute')` must be false. Nothing changes for anyone until an owner gives somebody the level «مخصص».

## 4. Rollback
`…_phase28_admin_custom_permissions_ROLLBACK.sql` (`psql -1`): demotes every custom admin to «مشاهدة فقط» (viewer) — so nobody keeps a level the old database does not know — restores the phase 26 texts of `limited_admin`, `require_company_admin` and `my_admin_context`, undoes the two text patches, drops the two functions, the two helpers and the three tables, and restores the role check without `custom_admin`.
- **What stays:** the audit rows (`admin.role_changed`, `admin.grants_changed`). The groups that were ticked are lost with the tables (they are only in the audit rows). The people who were custom admins become viewers: the owner can raise them again with the fixed levels.
- **Proof (2026-11-16):** a database built from every migration **except** 28 and a database built from **all** of them followed by the rollback were compared: 858 lines of functions (`md5(prosrc)`, security, volatility, settings, grants), columns, constraints and tables — **identical**; the data rollback was checked too on the final files (a database with two custom admins and their grants: after the rollback 0 custom admins, both are viewers, the grants table is gone). As a check that the comparison can see the change, "without 28" against "with 28" differs in 34 lines.
- The panel 12.27 against a database rolled back to 26 behaves as against a database without 28 (it hides «مخصص»).

## 5. Rulings and known limits (read before saying «نعم»)
1. **Every custom admin always has the viewer set** («الاطلاع العام»); groups only add. You cannot make an admin who sees only requests and not attendance. Lifting it later is a catalogue change plus panel tests.
2. **Groups re-slice what the HR level already may do, plus editing a movement's time.** New powers (holidays, company settings) stay owner-only; opening one later is one insert into the catalogue.
3. **Salary visibility follows the employee file.** The group «ملفات الموظفين (تشمل الرواتب)» opens `admin_get_employee_profile`, which returns the salary; the group's name and hint say so. Hiding the salary from a file editor needs a change inside that function: not done.
4. **Groups follow screens, not topics** (changed during the build). The first cut had a group for grace, punch windows, geofence and devices; but the employee form calls grace, punch-window and device functions, so an admin with the file group alone would have had a half-refused form. The employee form's functions are all in `employees`; `workplace` is the geofence and location policy only. Two catalogue functions (`admin_update_employee`, `admin_set_employee_location_policy`) are not called by this panel; they are in the groups because phase 26 already gave them to the HR level.
5. **Combinations** are tested group by group and all four together, not every one of the 16 combinations: a group only adds functions and the panel gates by function, so a combination is the union of what each group shows. The database side sweeps all 81 functions for each group.
6. **A new `admin_*` function is owner-only until someone inserts it into a group** (default deny stays).
7. **Older panel 12.26 refuses a custom admin** (see §3). The panel 12.27 and a database without phase 28 work together.
8. **Not done, by decision:** the companies window and the company-wide isolation sweep (Omar skipped it). Only the isolation of the new grants is tested (a grant of another company is inert; the owner of company B cannot grant in company A).
9. **Not caused by this work:** closing the geofence dialog the instant it opens raises a Leaflet script error (also for the owner). Left as it was.
10. **Review:** there was no separate reviewer for this work; the checks above (red-first tests, mutation checks, rollback proof, strict-fake runs per group) and a read-through of my own diff are the review. A fresh pair of eyes on `require_company_admin` (the gate of every admin function, the riskiest line of the work) before applying it would be wise.

