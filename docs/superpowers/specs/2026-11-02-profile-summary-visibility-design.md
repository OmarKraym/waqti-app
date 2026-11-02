# Employee profile summary with admin-controlled visibility — design

Date: 2026-11-02 · Status: draft, waiting for review · Path: architectural (new column, new functions, new screen section, admin panel change)

## 1. What Omar asked, and what "done" means

> "Add a summary of the employee's data on the profile page, and let the system admin show or hide the data in detail — for example one item shows and the others stay hidden."

Decisions already made with Omar:

- **Company default only.** The admin sets one list of switches for the whole company. No exceptions for single employees.
- The admin panel is a separate local web app (not in this repo). This spec describes what it must do; the code for it comes after Omar sends the panel files.

Success criteria:

1. An employee opens **Profile** and sees a "ملخص بياناتي" (My data summary) section with only the items the admin allows.
2. The admin can switch each item on or off. Saving takes effect for all employees, with no app update.
3. A hidden item **never leaves the server**. Hiding is not done in the app. The employee cannot get it with a modified app or a direct API call.
4. Nothing new is exposed until the admin turns it on: salary, birth date and gender start hidden.
5. Every change by the admin is written to the audit log.

## 2. Out of scope (this version)

- Per-employee exceptions (Omar chose company default only).
- Editing data from the employee app. The summary is read-only.
- A "tap to reveal" for salary (shoulder-surfing protection). Good idea for later; not needed to meet the goal.
- Offline copy of the summary. It needs internet, like the other server screens.
- Changing what the admin panel itself shows. Admins always see all employee data there.

## 3. The items

Always shown, not configurable (they are already in the profile header and account card): full name, employee number, company, e-mail.

Eleven configurable items. Key = the name stored in the database and sent by the admin panel.

| Key | Arabic label | Group | Default |
|---|---|---|---|
| `department` | القسم | الوظيفة | shown |
| `job_title` | المسمى الوظيفي | الوظيفة | shown |
| `work_location` | موقع العمل | الوظيفة | shown |
| `hire_date` | تاريخ التعيين (+ مدة الخدمة) | الوظيفة | shown |
| `schedule` | جدول الدوام | الدوام | shown |
| `leave` | الإجازات المستحقة (كل نوع وعدد أيامه) | الإجازات | shown |
| `salary_base` | الراتب الأساسي | الراتب | **hidden** |
| `salary_components` | البدلات والعلاوات | الراتب | **hidden** |
| `salary_total` | إجمالي الراتب | الراتب | **hidden** |
| `birth_date` | تاريخ الميلاد | شخصي | **hidden** |
| `gender` | الجنس | شخصي | **hidden** |

Key to JSON field: `department`, `job_title`, `hire_date`, `birth_date`, `gender` → `employee.<key>`; `work_location` → `employee.work_location_name`; `schedule` → `schedule`; `leave` → `leave`; `salary_base` / `salary_components` / `salary_total` → `salary.base_salary` / `salary.components` / `salary.total`.

The three salary items are independent. Example: the admin can show only the total and hide the base and the components.

## 4. Database

One migration: `supabase/migrations/20261102130000_phase11_profile_visibility.sql` and its `_ROLLBACK.sql`. It follows the existing pattern (guard block, security definer, `search_path` fixed, `revoke` then `grant`).

### 4.1 Storage

```sql
alter table public.companies
  add column profile_visibility jsonb not null default '{}'::jsonb
  check (jsonb_typeof(profile_visibility) = 'object');
```

`private.profile_visibility_defaults()` returns the default map from section 3. The effective setting is `defaults || stored`. A key that is missing in the stored value uses the default. This means: a new item added later is hidden or shown by its default, with no data migration; and unknown keys in the stored value are ignored.

### 4.2 Functions

| Function | Who | What |
|---|---|---|
| `public.employee_profile_summary()` → jsonb | signed-in active employee | Reads the **caller's own** record (`auth.uid()`, via `require_active_employee()`). Builds the result and **leaves out every hidden item**. |
| `public.admin_get_profile_visibility()` → jsonb | company admin (`require_company_admin()`) | Returns the effective map `{key: boolean}` for all 11 keys. |
| `public.admin_set_profile_visibility(p_visibility jsonb)` → jsonb | company admin | Validates, merges into the stored value, writes the audit entry, returns the new effective map. |

`admin_set_profile_visibility` rules:

- The input must be a JSON object. Any key outside the 11 keys → `invalid_profile_visibility`. Any value that is not a boolean → `invalid_profile_visibility` (errcode `22023`, like the other settings).
- It **merges**: keys that are not sent keep their old value. The panel normally sends all 11.
- Audit: `audit_write(company, 'company.profile_visibility', 'company', company_id, {changed: {key: {from, to}}})`. If nothing changed, no audit row.

Result shape of `employee_profile_summary()`. A hidden item has no key at all, so the employee cannot see that something is hidden. A visible item with no data is `null` or empty, and the app does not draw it.

```json
{
  "employee": { "department": "...", "job_title": "...", "work_location_name": "...",
                "hire_date": "2022-03-01", "gender": "male", "birth_date": "1990-05-02" },
  "schedule": [ { "weekday": 6, "is_workday": true, "start_time": "08:00", "end_time": "16:00" } ],
  "salary":   { "base_salary": 1500, "components": [ { "name": "...", "amount": 200 } ], "total": 1700 },
  "leave":    [ { "type": "annual", "days": 30, "is_default": true } ]
}
```

Here each part appears only when its key is on: `employee.*` per key; `schedule`; `salary.base_salary` / `salary.components` / `salary.total` per key (the `salary` object is left out if all three are off); `leave`.

### 4.3 The old `get_my_profile()`

`public.get_my_profile()` already exists. It returns the same data, **including salary, with no filter**, to any signed-in employee. The app does not call it today, but anyone can call it directly. If we only add a new function, hiding salary would be fake.

Decision: in the same migration, `get_my_profile()` becomes a one-line wrapper (`return public.employee_profile_summary()`). There is one filter and one door. Callers get the same shape, minus hidden items. This is a tightening: by default `get_my_profile()` stops returning salary, birth date and gender. A test proves it. The new function also uses `require_active_employee()`, so an account that must still change its password gets `must_change_password`, like every other employee function.

### 4.4 Grants

`revoke all … from public, anon;` then `grant execute … to authenticated;` for all three (and for `get_my_profile`, unchanged). The admin functions check the role inside through `require_company_admin()`.

## 5. Employee app (PWA)

- `types.ts`: `ProfileSummary` type (all parts optional, matching 4.2). `api.ts`: `getProfileSummary(): Promise<ProfileSummary>`. `supabaseApi.ts`: `rpc("employee_profile_summary")`. `mockApi.ts`: returns a full record filtered by the URL parameter `?summary=default|all|none` (default = the company defaults in section 3), so the screen can be tried and tested without a server.
- `lib/profileSummary.ts` (pure, unit-tested):
  - `serviceLength(hireDate, today)` → "٣ سنوات و ٤ أشهر" style text (years and months; under one month → "أقل من شهر"; future date → nothing).
  - `groupSchedule(rows)` → weekday ranges with the same hours, in the Libyan week order Saturday → Friday. Example: "السبت – الأربعاء ٠٨:٠٠–١٦:٠٠ · الخميس ٠٨:٠٠–١٣:٠٠ · الجمعة إجازة". (`weekday` follows PostgreSQL `dow`: 0 = Sunday.)
  - `summaryGroups(summary)` → the list of groups and rows to draw. Rows with no value are dropped, and a group with no rows is dropped.
- `Profile.tsx`: new section **"ملخص بياناتي"** after the account card and before the theme card. One card per group (الوظيفة, الدوام, الإجازات, الراتب, شخصي), each a `dl` in the existing `info-list` style. States: loading (short skeleton), offline ("يلزم اتصال بالإنترنت لعرض ملخص بياناتك"), error (message + retry button), and nothing visible (the whole section is not drawn). The data is fetched when Profile opens, not on Today, and it is not cached.
- Colors and dark mode: use the existing tokens only. Money in LYD with `dir="ltr"` numbers, tabular figures.
- Texts that the employee sees never say "hidden by admin".

## 6. Admin panel (contract, not code yet)

New dialog **"ظهور بيانات الموظف"** opened from the company settings area:

- Loads `admin_get_profile_visibility()`. Shows the 11 items in the same 5 groups, one switch each, with the Arabic labels from section 3.
- Buttons: **إظهار الكل**, **إخفاء الكل**, **الإعداد الافتراضي** (sets the switches to the defaults, nothing saved yet), and **حفظ**.
- Save sends all 11 keys to `admin_set_profile_visibility`. After saving, show "تم الحفظ — يسري على جميع الموظفين عند فتح صفحة حسابي".
- A short note under the title: "هذا الإعداد لكل الشركة، ولا يؤثر على ما تراه أنت في لوحة التحكم."
- The panel files are now available (`waqti_admin_11.zip`). This dialog is built as the **«ظهور بيانات الموظف» pane of the new Settings window**, see `2026-11-02-admin-panel-rebuild-design.md` (section 6). It calls the two functions above. If the migration is not applied yet, the pane shows "غير متاح بعد" instead of failing.

## 7. Errors

| Code | When | App text |
|---|---|---|
| `forbidden` | non-admin calls an admin function | existing text |
| `invalid_profile_visibility` | bad key or non-boolean value | "قيمة غير صالحة. حدّث الصفحة وحاول مرة أخرى." (admin panel only) |
| `employee_inactive`, `not_authenticated`, `must_change_password` | existing employee rules | existing texts |

## 8. Tests

**SQL** (`supabase/tests/phase11_profile_visibility_tests.sql`, run by `supabase/local/test-db.sh` on a throwaway copy):

1. Defaults: a company with `{}` returns department, job title, location, hire date, schedule, leave — and **no** salary, birth date, gender.
2. Each of the 11 keys turned on alone returns exactly that item and nothing else sensitive.
3. All off → the result has no optional keys. All on → full record, salary total = base + components.
4. A salary item hidden is **absent** (not `null`) in the JSON text.
5. `get_my_profile()` equals `employee_profile_summary()` and no longer returns salary by default.
6. An employee cannot read another employee's data (the result always belongs to `auth.uid()`); a company-A admin cannot change company B (the test creates a second company if the seed has only one); a normal employee gets `forbidden` from both admin functions.
7. Bad key, non-boolean, non-object → `invalid_profile_visibility`; nothing is saved.
8. Merge: sending one key keeps the other values. Audit row written once per real change, with from/to; none for a no-op.
9. Inactive employee and inactive company → refused.
10. The rollback file restores the old `get_my_profile()` and drops the column and functions (checked by running it on a copy).

**PWA** (vitest): `serviceLength`, `groupSchedule` (ranges, week order, days off, split shifts), `summaryGroups` (hidden parts, empty parts), mock API with the three `?summary=` modes, and a render check that nothing sensitive shows with `?summary=default`. The existing `palette.test.ts` keeps guarding colors in both themes.

**Manual / visual**: screenshots of Profile in light and dark with `?summary=default`, `all`, `none`, offline, and error.

## 9. Rollout

Order matters:

1. **Migration first** (backward compatible: new column, new functions; the defaults hide the sensitive items). Applied to production **only after Omar says yes**; tested first on the local copy.
2. Deploy the PWA (`scripts/deploy-gh-pages.sh`). An old PWA keeps working because it does not call the new function.
3. Update the admin panel.

Until step 3, the admin has no screen to change the switches, so the company stays on the defaults. That is a safe state.

## 10. Risks and open points

- **Inference leak:** when an employee has no saved annual leave, the default is 30 days, or 45 for age 50 and over. If `birth_date` is hidden but `leave` is shown, an employee can see "45" and learn the age band. Accepted for this version; the admin note in the dialog will mention it.
- **One setting for everyone:** a manager cannot be allowed to see data that staff cannot. This is the "company default only" choice. If it becomes a need, a per-employee override can be added later without changing these functions' shape.
- **Screen exposure:** if salary is turned on, it is visible to anyone looking at the phone. "Tap to reveal" is the planned follow-up (section 2).
- **Admin panel code** was received later (2026-11-02). Its part of this work is planned inside the admin panel rebuild, not as a separate change to the old `app.js`.
