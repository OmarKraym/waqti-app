# Custom request kinds — design

Date: 2026-11-09 · Status: draft, waiting for review · Path: architectural (new table, changes to the request submit/overview functions, admin panel pane, employee app)
Phase: 24 · Panel: 12.23 · Source: the attached spec «تطوير مرونة لوحة إدارة وقتي», narrowed in the brainstorming Q&A below.

## 1. What Omar asked, and what "done" means

The attached spec asked for a full dynamic request engine (form builder, approval engine, rules engine, versioning, attachments). Through the Q&A Omar narrowed it to this:

- The requests that exist today stay exactly as they are in the app.
- The admin can add **new kinds** with their own name and settings, in **two families only**:
  - **New leave types** (new names next to annual, sick, emergency, marriage, maternity, unpaid).
  - **New «طلب آخر» types** (new names next to the current «طلب آخر»).
- The audience is **everyone** (no targeting by department or branch).
- **No attachments**, no custom field builder, no advanced workflow (parallel approval, return-for-info, delegation), no wider rules engine.

Settings per family, as chosen by Omar:

| Family | Settings |
|---|---|
| Leave | days per year (general default + per-employee override), gender (all / women only / men only), reason required or not |
| Other | own approval chain per kind, date mode (one day / a period / no date) |

Constraints from the attached spec that stay in force: do not change the production database directly, do not publish without Omar's approval, deliver the migration as its own file, document the change, run regression tests.

**Done means:** an admin can create a kind in the panel, an employee sees it in the app without a new deploy of the data, can submit it, the request follows the right chain, and every rule is enforced by the database. Existing requests and the 1417 existing tests behave exactly as before.

### Assumptions (said by nobody, decided here — correct me if wrong)

1. A custom leave behaves like **sick leave** everywhere downstream: a paid leave, counts as an approved leave day for attendance, no salary deduction, balance by calendar year, a leave cannot cross a year.
2. A custom «other» request has **no effect on attendance or pay**, like today's «طلب آخر». It is a request with a decision.
3. Reason is **always required** for a custom «other» (as today's «طلب آخر»). The "reason required" switch exists for leave kinds only.
4. Per-employee days are an **override of a number**. There is no per-employee "unlimited" when the kind has a limit.
5. A gender-restricted kind refuses an employee whose gender is empty (same as maternity today).
6. `requests.start_at/end_at` are `NOT NULL` today. A kind with date mode "no date" stores the **filing day** as a one-day period; the app and panel do not show it.

## 2. Approach

Three approaches were compared with Omar. Chosen: **one additional table with a family column, additive changes only, mirroring the `permission_types` pattern** (phase 4d). Rejected: a generic field-builder engine (too large for what is needed, and the user dropped it), and one table per family (duplicates the admin RPCs, the panel pane and the chain logic).

Why additive: the six built-in leave types and the current «طلب آخر» are checked by name in many places (the `leave_type` check constraint, notification labels, leave ordering, balance logic). Leaving them untouched is the cheapest way to guarantee "stays as it is".

## 3. Database (migration `20261111090000_phase24_custom_request_kinds.sql` + `_ROLLBACK.sql`)

### 3.1 New tables

`custom_request_kinds`

| Column | Type / rule |
|---|---|
| `id` | uuid PK, `gen_random_uuid()` |
| `company_id` | uuid not null, FK companies; `unique (company_id, id)` |
| `family` | text not null, `'leave'` or `'other'`; never changes after creation |
| `name` | text not null, 1–60 characters after trim |
| `enabled` | boolean not null default true |
| `sort_order` | smallint not null default 0 |
| `default_days` | numeric(5,1), 0–366; leave only; NULL means unlimited |
| `gender` | text not null default `'all'`, one of `all`, `female`, `male`; leave only |
| `reason_required` | boolean not null default false; leave only |
| `date_mode` | text, one of `single`, `range`, `none`; other only |
| `created_at`, `updated_at` | timestamptz |

- Unique name inside a family: `unique (company_id, family, lower(btrim(name)))`.
- Family check: a leave row has `date_mode is null`; an other row has `date_mode is not null`, `default_days is null`, `gender = 'all'`, `reason_required = false`.
- At most 30 kinds per family per company (enforced in the save RPC).
- RLS on, no direct grants. Only the RPCs below touch it.

`custom_kind_entitlements` (per-employee days for a leave kind)

- Columns `company_id`, `kind_id`, `employee_id`, `days numeric(5,1)` (0–366). PK `(kind_id, employee_id)`.
- Same-company foreign keys to the kind and to the employee, `on delete cascade` for both.
- A separate table, not new keys in `employee_leave_entitlements`: that table has a check that allows only the six built-in names, and `private.leave_balance` reads it. Keeping the two apart means that long function is not changed.

### 3.2 Changes to existing tables

- `requests.custom_kind_id uuid`, composite FK `(company_id, custom_kind_id)` to the kind, **`on delete restrict`**. This gives "no delete after use" for free.
- `requests.leave_type` check gets one more value, `'custom'`.
- Row rules (new check constraint):
  - custom leave → `request_type = 'leave'`, `leave_type = 'custom'`, `custom_kind_id` set;
  - custom other → `request_type = 'other'`, `leave_type` null, `custom_kind_id` set;
  - today's «طلب آخر» keeps `custom_kind_id` null; permission requests never have one.
- `approval_steps.custom_kind_id uuid` (FK to the kind, `on delete cascade`). The unique index becomes `(company_id, request_type, coalesce(permission_type_id, zero-uuid), coalesce(custom_kind_id, zero-uuid), step_order)`. Only custom **other** kinds use it; custom leave kinds use the shared leave chain.

### 3.3 Functions

New (all `security definer`, `search_path` fixed, revoked from `public`/`anon`, granted to `authenticated`, admin ones start with `require_company_admin()`):

| Function | Purpose |
|---|---|
| `admin_list_custom_kinds()` | all kinds of the company with total and pending request counts |
| `admin_save_custom_kind(p_id, p_family, p_name, p_enabled, p_default_days, p_gender, p_reason_required, p_date_mode, p_sort_order)` | create (`p_id` null) or update; family cannot change; validates the family-specific fields |
| `admin_delete_custom_kind(p_id)` | only when no request ever used it, else `kind_in_use` |
| `admin_get_employee_kind_days(p_employee)` / `admin_set_employee_kind_days(p_employee, p_days jsonb)` | `{kind_id: days or null}`; null removes the override |
| `private.custom_leave_balance(p_employee, p_kind, p_year, p_exclude_request)` | entitled = override if present else `default_days`; used = approved (`coalesce(charged_days, days)`), pending = pending, same shape as `private.leave_balance`; `remaining` null when unlimited |

Changed (each `create or replace`, same grants; the old signature is dropped first when a parameter is added, so no overload is left behind):

| Function | Change |
|---|---|
| `employee_submit_request` | new last parameter `p_custom_kind_id uuid default null`. When set, the server loads the kind (same company, enabled) and ignores `p_leave_type`. Old app builds keep working because the new parameter has a default. |
| `private.request_chain` | new parameter `p_custom_kind_id`; looks up chain rows for the kind; falls back to direct_manager then hr, as today |
| `admin_get_approval_chains`, `admin_set_approval_chain` | accept the kind id next to `p_permission_type_id` |
| `private.request_json` | adds `custom_kind_id` and `kind_name` (read live, so a rename shows in old requests) |
| `employee_requests_overview` | adds `custom_kinds`: enabled kinds the employee may use (gender filtered), each leave kind with its balance |
| `private.request_summary` (notification text) | the label of a custom request is the kind name |
| `private.apply_decision` | only the final-approval balance re-check: a request with `leave_type = 'custom'` is checked with `private.custom_leave_balance`. Without this, `private.leave_balance(..., 'custom', ...)` finds no entitlement row and treats the leave as unlimited. |

Unchanged on purpose: `approver_decide`, `admin_decide_request` (HR may still charge fewer days; `custom` is not `unpaid`), `private.can_decide`, cancel. The chain is frozen into `request_approvals` at submit, so the decision flow does not need to know about kinds.

### 3.4 Rules (all in the database)

**Custom leave** (`p_type = 'leave'` + kind):
1. Kind must exist in my company and be enabled, else `custom_kind_not_found` / `custom_kind_disabled`.
2. Gender: `female` needs my gender = female, `male` needs male, else `kind_gender_mismatch`.
3. Dates, year crossing, working days: exactly the built-in leave rules (`invalid_dates`, `crosses_year`, `no_working_days`).
4. `reason_required` and no reason → `reason_required`.
5. Balance by `private.custom_leave_balance`, with the built-in over-balance behavior: more than the remaining needs a reason (`insufficient_balance` without one) and is marked `over_balance` for HR to decide. Unlimited kind: no check.
6. Overlap with my other pending/approved leave or permission is refused, as for built-ins.
7. Approvers come from the shared leave chain.

**Custom other** (`p_type = 'other'` + kind):
1. Kind exists, same company, enabled; reason required (`reason_required`).
2. Date mode:
   - `single` → one date; `end = start`; today−30 … today+365 window as today;
   - `range` → start and end as today's «طلب آخر»;
   - `none` → the filing day (today in the company time zone) is stored as a one-day period.
3. Approvers come from the chain of that kind; no chain saved → direct_manager then hr. Steps with no approver are skipped as today.

**Kind lifecycle:**
- Disable: no new requests; pending and old requests continue and show normally.
- Delete: only a kind with no request, otherwise disable.
- Rename: shows everywhere, including old requests.
- Changing `default_days`, `gender` or `date_mode` affects **future** submissions. A lower `default_days` can make an old balance negative; that is accepted and shown as is.

**Security:** every admin function checks admin of the same company; a kind id from another company is "not found". Every create/update/delete/days change writes `public.audit_write` (action names copied from the permission-type audit entries). No grants on the two new tables.

**Downstream consumers (checked against the code on 2026-11-10).**
- Read the kind name from the kind: `private.request_json` (so the Requests tab, the admin list and the Excel export get it), `private.request_summary` (notification text), `private.apply_decision` (balance re-check, above).
- Unaffected: profile summary and punch-window profile (phases 8a, 8b, 16c) read `employee_leave_entitlements` only, which custom kinds do not use; `leave_days` and holidays do not look at `leave_type`.
- Carry `leave_type = 'custom'` and show the generic label «إجازة خاصة» (not the kind name): the leave-conflict and review-queue payloads of phases 15, 22 and 23 and the metadata a punch on a leave day stores. Putting the name there would change the punch function, which is on the hottest path, for a polish gain. A later phase can add it.

## 4. Admin panel 12.23

- **New settings pane «أنواع الطلبات»** in the group «الموافقات والبيانات» (`js/settings/request-kinds.js`, registered in the `PANES` array of `js/settings/index.js`).
  - Table: name, family badge (إجازة / طلب آخر), request count, status badge (مفعّل / معطّل), edit.
  - «+ إضافة نوع» first asks the family, then shows that family's form:
    - Leave: name, days (empty = unlimited), gender, reason required.
    - Other: name, date mode (يوم واحد / فترة / بدون تاريخ).
  - Enable/disable switch. Delete shows only for a kind with no requests.
- **Approvals pane:** one chain editor per custom «other» kind, same editor as permission types.
- **Employee form (existing employees):** one days field per enabled custom leave kind, placeholder "الافتراضي: N" (or "غير محدود"); empty = use the default. Saved through `admin_set_employee_kind_days` right after the profile save, only for the values that changed. The create form shows a hint that these days are set after the account exists.
- **Requests tab, review card, export, `js/lib/leave-text.js`:** show `kind_name` from the server for custom requests.
- Layout tests keep the three widths used by earlier phases.

## 5. Employee app

One app release is needed once, to understand the new shape. After that a new kind appears without any deploy.

- `src/lib/types.ts`, `requests.ts`, `errors.ts`, `mockApi.ts`, `screens/Requests.tsx`.
- Leave select: the six built-ins first, then custom leave kinds that have a balance row; the balance line uses the kind's numbers.
- «طلب آخر»: a type select, today's «طلب آخر» first, then custom other kinds. Date inputs follow the kind's `date_mode` (one date / two dates / none).
- Request cards, history and notifications show `kind_name`.
- New error texts: `custom_kind_not_found`, `custom_kind_disabled`, `kind_gender_mismatch`.
- No custom fields: the «other» form stays reason-only.

## 6. Tests and delivery (everything local)

- **Database:** `supabase/tests/phase24_custom_request_kinds_tests.sql`, written first and seen RED. Cases: over balance with and without reason; gender mismatch and empty gender; reason required; disabled kind; per-employee override beats default; unlimited kind; the three date modes; own chain and the default fallback; chain frozen after the chain is edited; approve and reject flow; cancel; company isolation (other company's kind id); grants (anon and authenticated cannot read the new tables); audit rows; delete refused after use; rename visible in old requests; old-signature call of `employee_submit_request` still works.
- **Regression:** all 1417 existing tests stay green, plus mutation checks on the changed functions (`employee_submit_request`, `private.request_chain`).
- **Panel:** unit tests for the pane logic, behavior tests with fake RPCs, layout tests at three widths.
- **App:** unit tests for `requests.ts` and a clean build.
- **Delivery files:** `docs/PHASE24_RUN_LOCALLY.md` (function fingerprints and the apply steps), the panel 12.23 zip, the app build.
- **Apply order, later and only on Omar's words:** migration → panel → app. Between the steps nothing breaks: kinds created in the panel before the app release are simply not visible to employees, and no custom request can exist before the app can submit one.
- Rollback file refuses to run if any request already has a `custom_kind_id` (no silent data loss).
- Nothing is applied to production, pushed or deployed by this work.

## 7. Out of scope

Attachments; a custom field builder; parallel, return-for-info or delegated approvals; a wider rules engine; targeting by department/branch; versioning of kinds; new permission or overtime types (permission types already support adding); changing the six built-in leave types or today's «طلب آخر».

## 8. Risks

- `employee_submit_request` is long and sits in the hottest path. The change is one new parameter and two new branches; the regression suite and mutation checks are the guard. The balance logic is **not** touched (a new function is used).
- `private.request_chain` gets a new parameter; the old signature must be dropped in the same migration so no overload remains. The fingerprints in `PHASE24_RUN_LOCALLY.md` catch drift.
- A reader of `leave_type` that nobody remembers would show an empty label for `'custom'`. Mitigation: every reader in the migrations, the panel and the app was listed on 2026-11-10 (section 3.4); the plan adds the label `custom` = «خاصة» to both label tables so no screen shows an empty word.
- Production migration history is missing the 18a/18b names although their functions exist; the apply steps must compare function fingerprints, not migration names.
