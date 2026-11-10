# Custom Request Kinds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The admin can add new leave types and new «طلب آخر» types in the panel; employees see and submit them in the app; every rule is enforced by the database.

**Architecture:** One migration (phase 24) adds `custom_request_kinds` (+ `family` column) and `custom_kind_entitlements`, two nullable columns (`requests.custom_kind_id`, `approval_steps.custom_kind_id`) and a handful of new/changed functions, mirroring `permission_types` (phase 4d). The six built-in leave types and today's «طلب آخر» are not touched. The panel gets one settings pane plus small changes; the app gets a kind-aware form.

**Tech Stack:** Postgres 16 / Supabase (plpgsql, `supabase/tests/*.sql` run by `supabase/local/test-db.sh`), admin panel in plain ES modules (`/home/claude/waqti-admin`, `node --test`, Playwright scripts in `tests/ui`), employee app in React/Vite/TS (`/home/claude/waqti-app`, `vitest`).

**Spec:** `docs/superpowers/specs/2026-11-09-custom-request-kinds-design.md` (binding; this plan argues from it).

## Global Constraints

- **Nothing leaves the machine.** No production migration, no push, no deploy, no panel/app publish. Production is only read, and only with `SELECT` (Task 8, fingerprints). Commits are local. A production apply needs Omar's «نعم», a push his «ارفع», a deploy his «انشر».
- **One migration file**, built up task by task: `supabase/migrations/20261111090000_phase24_custom_request_kinds.sql`, with `…_ROLLBACK.sql` beside it. Each task appends its own section. No backslash escapes in the SQL text (the apply tool mangles them). No `pg_cron`.
- **Function rules** (same as phase 4d): `security definer`; `set search_path = 'public'` for `public.*`, `set search_path = ''` for `private.*`; `revoke all … from public, anon`; `public.admin_*` start with `public.require_company_admin()` and are granted to `authenticated`; employee functions start with `public.require_active_employee()`; `private.*` are granted to nobody. Every admin change calls `public.audit_write`.
- **Values:** kind name 1–60 characters after trim, unique per company+family ignoring case; at most 30 kinds per family per company; `default_days` and per-employee days 0–366 (`0` = no days allowed, `NULL` = unlimited — these two must never be confused); `gender` ∈ `all|female|male`; `date_mode` ∈ `single|range|none`; family ∈ `leave|other` and never changes.
- **Error codes** (new): `custom_kind_not_found`, `custom_kind_disabled`, `kind_gender_mismatch`, `kind_name_taken`, `kind_in_use`, `kind_limit`. Reused as they are: `invalid_input`, `invalid_dates`, `crosses_year`, `no_working_days`, `reason_required`, `insufficient_balance`, `overlapping_request`, `employee_not_found`. Errors are raised as in phase 4d: `raise exception '<code>' using errcode = '22023'` (or `P0001` where the existing code uses it).
- **Compatibility:** `employee_submit_request` called with its old 10 arguments, and `admin_set_approval_chain` called with its old 3 arguments, keep working unchanged. A request of today's «طلب آخر» keeps `custom_kind_id` null and the plain «طلب آخر» chain.
- **Regression:** the 1417 existing DB tests stay green. Full run: `cd supabase && bash local/test-db.sh` → `TOTAL passed=<1417+new> failed=0`. One DB run at a time (the runner rebuilds `waqti_test`); the server clock is fixed at 2026-10-31 10:00 (libfaketime) as in `docs/PHASE23_RUN_LOCALLY.md`.
- **Two folders:** the database, app and documents live in the git repo `/home/claude/waqti-app` (commits there). The admin panel lives in `/home/claude/waqti-admin`, which is **not** a git repo: panel tasks end with test results and the zip, not a commit.
- **Panel:** version `12.23.0` in `package.json`; no build step, no new dependency; every new text is Arabic, RTL, and goes through `h()` (no `innerHTML`). **App:** no new dependency; `npm test`, `npm run typecheck`, `npm run build` stay green.
- **Labels:** `custom` → «خاصة» in both label tables (panel `LEAVE_LABEL`, app `LEAVE_LABEL`) so no screen shows an empty word.

## Review Focus

Failure modes the spec implies; each has a test in the task named.

1. A kind's chain leaks into the plain «طلب آخر» chain (or the reverse): `request_chain` and `admin_set_approval_chain` match `custom_kind_id` with `is not distinct from`, and `admin_get_approval_chains.customized` must ignore kind rows. (Task 4)
2. Final approval of a custom leave skips the balance re-check (treated as unlimited) because `private.leave_balance` knows no `'custom'` entitlement. (Task 7)
3. `0` days treated as unlimited, or empty treated as 0: default 0 blocks every request, default NULL never does; the panel maps an empty field to NULL and `"0"` to 0. (Tasks 2, 3, 9)
4. A kind id of another company (or of the other family) accepted by any RPC: submit, save, delete, days, chain. (Tasks 2–6)
5. A kind disabled or deleted between the overview and the submit; an old app build submitting with 10 arguments; the same request key sent twice. (Tasks 5, 6)

## File Structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20261111090000_phase24_custom_request_kinds.sql` (+ `_ROLLBACK.sql`) | all database changes |
| `supabase/tests/phase24_custom_request_kinds_tests.sql` | all phase 24 DB tests (one file, one `do $tests$` block per task) |
| `/home/claude/waqti-admin/js/settings/request-kinds.js` | the «أنواع الطلبات» pane and its pure helpers |
| `/home/claude/waqti-admin/js/settings/approvals.js`, `js/employee-form.js`, `js/requests.js`, `js/lib/leave-text.js`, `export.js`, `js/core/errors.js`, `js/settings/index.js` | small changes |
| `/home/claude/waqti-admin/tests/request-kinds.test.mjs`, `tests/kind-names.test.mjs`, `tests/ui/*` | panel tests |
| `src/lib/types.ts`, `requests.ts`, `errors.ts`, `mockApi.ts`, `src/screens/Requests.tsx`, `src/lib/requests.test.ts` | app |
| `docs/API_CONTRACT.md` (§12), `CHANGELOG.md`, `docs/PHASE24_RUN_LOCALLY.md` | documents |

## Rulings the plan makes (the spec was silent or is amended)

- **P1** `private.apply_decision` changes (final-approval balance re-check). The spec said "unchanged"; it is amended.
- **P2** Phase 15/22/23 payloads keep `leave_type: 'custom'` and show «إجازة خاصة»; the kind name appears everywhere `request_json` / `request_summary` are used. Amended in the spec.
- **P3** Date mode `single`: the server uses `p_start_date` and ignores `p_end_date`. `none`: both dates are ignored; the stored period is today (company time zone). `range`: as today's «طلب آخر».
- **P4** Per-employee days are editable on existing employees only; the create form shows a hint.
- **P5** `admin_set_employee_kind_days` touches only the keys it is given; a `null` value deletes that override.

## Test conventions (all DB tasks)

`supabase/tests/phase24_custom_request_kinds_tests.sql` copies the harness of `phase4d_permission_types_tests.sql` (the `t_res` table, `pg_temp.ok`, `pg_temp.as_user`, `pg_temp.err`, the final `do $report$` block) and adds helpers in Task 1: `pg_temp.kind(name text) returns uuid` (id of a kind by name), `pg_temp.sub_leave(kind uuid, d1 date, d2 date, dry boolean default false, reason text default null) returns jsonb` and `pg_temp.sub_other(kind uuid, d1 date, d2 date, reason text default 'x', dry boolean default false) returns jsonb` (calls of `employee_submit_request` with a fresh key and `p_custom_kind_id`), `pg_temp.sub_err(q text)`-style wrappers returning the error text. Every `do $tests$` block re-derives `v_admin, a, b, c, v_comp` the way phase 4d does, gives employees `a` and `b` a 7-day schedule (08:00–16:00) and uses dates from `v_today + 7` on (inside the 30-day window, all workdays). Run one file: `cd supabase && TESTS=tests/phase24_custom_request_kinds_tests.sql bash local/test-db.sh` → `phase24_custom_request_kinds_tests.sql: RESULT passed=<N> failed=0`.

---

### Task 1: Schema, constraints, test harness

**Files:**
- Create: `supabase/migrations/20261111090000_phase24_custom_request_kinds.sql` (section A), `…_ROLLBACK.sql` (section A undone), `supabase/tests/phase24_custom_request_kinds_tests.sql`

**Interfaces:**
- Produces: tables `public.custom_request_kinds`, `public.custom_kind_entitlements`; columns `requests.custom_kind_id`, `approval_steps.custom_kind_id`; constraint `requests_custom_kind_shape`; the recreated unique index `approval_steps_order_uidx`; test helpers listed above.

- [ ] **Step 1: Write the failing schema tests** (block 1 of the test file). Assertions, each its own `pg_temp.ok`:
  - both tables exist; RLS is on; `authenticated` and `anon` have no table privilege on either.
  - a valid leave row (`default_days` 10, `gender` `all`) and a valid other row (`date_mode` `single`) insert; rejected rows: leave with `date_mode`; other with `default_days`, with `gender = 'female'`, with `reason_required = true`; empty name; 61-character name; `gender = 'x'`; `default_days` 367 and −1; `date_mode = 'x'`; `family = 'x'`.
  - name uniqueness: same name in the same company+family differing only by case/spaces is rejected; allowed in the other family and in another company.
  - `custom_kind_entitlements`: `days` 367 rejected; second row for the same `(kind_id, employee_id)` rejected; rows vanish when the kind is deleted (cascade).
  - `requests`: `leave_type = 'custom'` accepted only with `request_type = 'leave'` and a `custom_kind_id`; `custom_kind_id` with `leave_type = 'annual'` rejected; with `request_type = 'permission'` rejected; `request_type = 'other'` with and without a kind both accepted; `leave_type = 'bogus'` still rejected; a kind of another company rejected (composite FK); deleting a kind that a request references fails (restrict).
  - `approval_steps`: step 1 for kind K and step 1 of the plain `other` chain coexist; a second step 1 for K is rejected; `custom_kind_id` with `request_type = 'leave'` rejected; a row with both `permission_type_id` and `custom_kind_id` rejected; deleting an unused kind deletes its chain rows.
- [ ] **Step 2: Run it** with the single-file command. Expected: FAIL (`to_regclass` is null, or `NO RESULT` because the first insert errors).
- [ ] **Step 3: Implement section A of the migration.**
  - `custom_request_kinds` and `custom_kind_entitlements` exactly as in spec §3.1 (`unique (company_id, id)`, `unique index on (company_id, family, lower(btrim(name)))`, the family check, `enable row level security`, `revoke all … from anon, authenticated`).
  - `requests`: add `custom_kind_id uuid`; FK `requests_custom_kind_same_company (company_id, custom_kind_id) → custom_request_kinds (company_id, id) on delete restrict`; replace the inline `leave_type` check (find its name in `pg_constraint` where `conrelid = 'public.requests'::regclass` and the definition contains `annual`; drop it in a `do` block) with one that also allows `'custom'`; add `requests_custom_kind_shape`: leave rows have `(leave_type = 'custom') = (custom_kind_id is not null)`; other rows may or may not have a kind; permission rows have none.
  - `approval_steps`: add `custom_kind_id uuid references public.custom_request_kinds (id) on delete cascade`, a check `custom_kind_id is null or (request_type = 'other' and permission_type_id is null)`, and replace `approval_steps_order_uidx` with the same index plus `coalesce(custom_kind_id, '00000000-0000-0000-0000-000000000000'::uuid)` before `step_order`.
  - Rollback section A: drop the index and recreate the phase 4d one, drop the two columns and constraints, restore the old `leave_type` check, drop both tables. It refuses (`raise exception 'rollback_refused_custom_requests_exist'`) when any request has `custom_kind_id` not null.
- [ ] **Step 4: Run the single-file command.** Expected: `passed=<N> failed=0`.
- [ ] **Step 5: Regression slice.** `TESTS="tests/phase24_custom_request_kinds_tests.sql tests/phase4_requests_tests.sql tests/phase4d_permission_types_tests.sql" bash local/test-db.sh`. Expected: `failed=0`.
- [ ] **Step 6: Commit** `feat(db): phase 24 - custom request kinds schema`.

---

### Task 2: Admin kind RPCs

**Files:**
- Modify: migration (section B), tests (block 2)

**Interfaces:**
- Consumes: Task 1 tables.
- Produces (all `public`, `authenticated` only):
  - `admin_list_custom_kinds() returns jsonb` — array of `{id, family, name, enabled, sort_order, default_days, gender, reason_required, date_mode, requests_count, pending_count}`, ordered by family, `sort_order`, name.
  - `admin_save_custom_kind(p_id uuid, p_family text, p_name text, p_enabled boolean, p_default_days numeric, p_gender text, p_reason_required boolean, p_date_mode text, p_sort_order integer default 0) returns uuid` — `p_id` null creates; on update `p_family` must equal the stored family (else `invalid_input`).
  - `admin_delete_custom_kind(p_id uuid) returns void`.
- Audit actions: `custom_kind.create`, `custom_kind.update`, `custom_kind.delete` (target type `custom_kind`, details with name/family).

- [ ] **Step 1: Write the failing tests** (block 2): list is empty at first and shows `requests_count`/`pending_count` once a request exists; create leave kind returns an id and writes one `custom_kind.create` audit row; update writes `custom_kind.update`; changing the family → `invalid_input`; same name differing by case/space → `kind_name_taken`; the 31st kind of a family → `kind_limit`; leave kind with `date_mode`, other kind with `default_days` / `gender` / `reason_required` → `invalid_input`; `default_days` 0 is stored as 0 and NULL as NULL (read back); delete of an unused kind works and audits `custom_kind.delete`; delete of a used kind → `kind_in_use`; the admin of a second company (`platform_create_company`) gets `custom_kind_not_found` on update/delete of the first company's kind and sees none in the list; an employee (not admin) is refused by all three; `anon` cannot execute any of them.
- [ ] **Step 2: Run the single file.** Expected: FAIL (functions do not exist).
- [ ] **Step 3: Implement section B.** Validate in this order: input shapes → name (trim, length) → family-specific fields → uniqueness (`kind_name_taken`, also catch `unique_violation`) → per-family count (`kind_limit`). Read `admin_save_permission_type` (phase 4d) for the exact style of the audit call and of error raising.
- [ ] **Step 4: Run the single file.** Expected: `failed=0`.
- [ ] **Step 5: Commit** `feat(db): phase 24 - admin RPCs for custom request kinds`.

---

### Task 3: Per-employee days and the custom balance

**Files:**
- Modify: migration (section C), tests (block 3)

**Interfaces:**
- Consumes: Task 2 (kinds).
- Produces:
  - `private.custom_leave_balance(p_employee uuid, p_kind uuid, p_year integer, p_exclude_request uuid default null) returns jsonb` → `{leave_type: 'custom', custom_kind_id, entitled, used, pending, remaining}`. `entitled` = the employee's override if there is a row, else the kind's `default_days` (NULL = unlimited, `remaining` NULL). `used` = sum of `coalesce(charged_days, days)` of approved requests of that employee and kind whose local start year is `p_year`; `pending` = sum of `days` of pending ones; `p_exclude_request` is left out. Same shape as `private.leave_balance`.
  - `public.admin_get_employee_kind_days(p_employee_id uuid) returns jsonb` → `{"<kind_id>": days, …}` (overrides only).
  - `public.admin_set_employee_kind_days(p_employee_id uuid, p_days jsonb) returns void` — `{"<kind_id>": number | null}`; null deletes the override; only the given keys change. Audit `custom_kind.days_set` (details: employee, the given map).

- [ ] **Step 1: Write the failing tests** (block 3): default 10, nothing used → remaining 10; override 5 beats the default; override removed (null) → back to 10; unlimited kind → `entitled` and `remaining` null; default **0** → remaining 0 (not null); used counts approved with `charged_days` when set, pending counts pending, cancelled/rejected count for nothing, another year counts for nothing, `p_exclude_request` excludes that row; another employee's requests are not counted; set days for a kind of another company → `custom_kind_not_found`; for an employee of another company → `employee_not_found`; days 367 or −1 → `invalid_input`; an other-family kind → `invalid_input`; audit row written; get returns only overrides; non-admin refused; `private.custom_leave_balance` not executable by `authenticated`.
- [ ] **Step 2: Run the single file.** Expected: FAIL.
- [ ] **Step 3: Implement section C.** Take the non-annual branch of `private.leave_balance` (phase 18a, the part after the `annual` block) as the model for the used/pending queries; filter by `custom_kind_id` instead of `leave_type`. Do not edit `private.leave_balance`.
- [ ] **Step 4: Run the single file.** Expected: `failed=0`.
- [ ] **Step 5: Commit** `feat(db): phase 24 - custom leave balance and per-employee days`.

---

### Task 4: Approval chain plumbing

**Files:**
- Modify: migration (section D), tests (block 4)

**Interfaces:**
- Changes (drop the old signature in the same section, as phase 4d did):
  - `private.request_chain(p_company uuid, p_type public.request_type, p_permission_type uuid default null, p_custom_kind uuid default null)` — both the rows branch and the default-path branch match `s.custom_kind_id is not distinct from p_custom_kind`.
  - `public.admin_set_approval_chain(p_request_type text, p_steps jsonb, p_permission_type_id uuid default null, p_custom_kind_id uuid default null)` — a kind is allowed only with `p_request_type = 'other'` and a kind of that company with `family = 'other'` (else `custom_kind_not_found` / `invalid_input`); the delete-then-insert matches `custom_kind_id is not distinct from`; audit details gain `custom_kind_id`.
  - `public.admin_get_approval_chains()` — the `customized` list ignores rows that have a `custom_kind_id`; new key `custom_kinds`: `[{id, name, enabled, customized, steps}]` for family `other` ordered like the list RPC.
- Consumed later: `request_chain(…, p_custom_kind)` by Task 6.

- [ ] **Step 1: Write the failing tests** (block 4): a kind K with no rows → its chain is `direct_manager`, `hr`, and `customized` false; set K = `[hr]` → `custom_kinds` shows `[hr]`, `customized` true, **and the plain `other` chain is still the default and `customized` (top level) does not contain `other`**; set the plain `other` chain = `[direct_manager]` → K's chain unchanged; empty array resets K only; kind of another company → `custom_kind_not_found`; kind with `p_request_type = 'leave'` or `'permission'` → `invalid_input`; a leave-family kind with `other` → `invalid_input`; `specific_employee` step works for K; old 3-argument named call still works; audit details contain `custom_kind_id`; the existing phase 4/4d chain tests still pass.
- [ ] **Step 2: Run the single file.** Expected: FAIL.
- [ ] **Step 3: Implement section D.** Start from the phase 4d texts of the three functions (`20261031100000_phase4d_permission_types.sql`); keep their behaviour for every existing call.
- [ ] **Step 4: Run** `TESTS="tests/phase24_custom_request_kinds_tests.sql tests/phase4_requests_tests.sql tests/phase4b_admin_managers_tests.sql tests/phase4c_progressive_tests.sql tests/phase4d_permission_types_tests.sql" bash local/test-db.sh`. Expected: `failed=0`.
- [ ] **Step 5: Commit** `feat(db): phase 24 - approval chains per custom kind`.

---

### Task 5: Submit a custom leave

**Files:**
- Modify: migration (section E), tests (block 5)

**Interfaces:**
- Changes: `public.employee_submit_request(p_request_key uuid, p_type text, p_leave_type text default null, p_start_date date default null, p_end_date date default null, p_start_at timestamptz default null, p_end_at timestamptz default null, p_reason text default null, p_dry_run boolean default false, p_permission_type_id uuid default null, p_custom_kind_id uuid default null)` — drop the 10-argument function first, recreate with the 11th parameter, regrant (`authenticated` only). Start from the phase 18a text (`20261105090000_phase18a_leave_years.sql`, the function that ends just before `private.apply_decision`).
- Produces for Task 6: a local `v_kind public.custom_request_kinds` loaded before the type branches; the `other` branch stays as it is in this task.

Behaviour added (spec §3.4, custom leave), in the order the existing code checks things:
  1. If `p_custom_kind_id` is not null: `p_type` must be `leave` or `other` (else `invalid_input`); load the kind of my company (else `custom_kind_not_found`); its family must match `p_type` (else `invalid_input`); not enabled → `custom_kind_disabled`.
  2. For a leave with a kind: `p_leave_type := 'custom'` (the argument is ignored); gender check (`female` needs `v_emp.gender = 'female'`, `male` needs `'male'`, a null gender fails) → `kind_gender_mismatch`; `reason_required` and no reason → `reason_required`.
  3. Dates, year crossing, working days exactly as for built-ins.
  4. Balance: `private.custom_leave_balance(me.employee_id, v_kind.id, year)`; more than `remaining` needs a reason (`insufficient_balance` without one when not a dry run) and sets `over_balance`; `remaining` null = no check.
  5. The insert stores `leave_type = 'custom'` and `custom_kind_id`; the dry-run result gains `custom_kind_id`; the chain is the shared leave chain (`request_chain(…, v_type, null, null)`).

- [ ] **Step 1: Write the failing tests** (block 5, kinds created with the Task 2 RPC): dry run of 3 days on a kind with default 10 → `balance.remaining` 10 and nothing saved; real submit stores `leave_type 'custom'`, the kind id, `days` 3, status pending, and the same approver steps as a built-in leave of the same employee; 4 days on a kind with default 3 → `insufficient_balance`, with a reason → saved and `over_balance` true; unlimited kind (default NULL) accepts 30 days; default **0** refuses 1 day; per-employee override 2 with a 3-day request → `insufficient_balance`; `female` kind with a male employee → `kind_gender_mismatch`, with an employee whose gender is null → same, with a female employee → ok; `male` kind symmetrical; `reason_required` kind without a reason → `reason_required`, with one → ok; disabled kind → `custom_kind_disabled`; a deleted kind id and a kind of another company → `custom_kind_not_found`; an other-family kind with `p_type 'leave'` → `invalid_input`; `p_type 'permission'` with a kind → `invalid_input`; `crosses_year`, `invalid_dates`, `no_working_days` still raised for a custom leave; an overlap with my own pending built-in leave → `overlapping_request`; passing `p_leave_type 'annual'` together with a kind id stores `custom` and leaves the annual balance untouched; the same request key twice → one row, second result `duplicate` true; **an old 10-argument positional call of a built-in leave still works** and a built-in leave's balance is unchanged by any custom request.
- [ ] **Step 2: Run the single file.** Expected: FAIL (11th parameter unknown).
- [ ] **Step 3: Implement section E** as described. Keep every other line of the 18a function byte-for-byte; the edit is the new parameter, the kind loading, the leave-type validity condition, three checks, the balance call and the insert columns.
- [ ] **Step 4: Run** `TESTS="tests/phase24_custom_request_kinds_tests.sql tests/phase4_requests_tests.sql tests/phase4d_permission_types_tests.sql tests/phase15_leave_conflict_tests.sql tests/phase18a_leave_years_tests.sql tests/phase18b_company_leave_days_tests.sql" bash local/test-db.sh`. Expected: `failed=0`.
- [ ] **Step 5: Commit** `feat(db): phase 24 - submit a custom leave`.

---

### Task 6: Submit a custom «other» request, chain freeze, decision flow

**Files:**
- Modify: migration (section F: the `other` branch and the chain call of `employee_submit_request`), tests (block 6)

**Interfaces:**
- Consumes: Task 4 `request_chain(…, p_custom_kind)`; Task 5's `v_kind`.
- Behaviour (spec §3.4, custom other; P3 above). In the `else -- other` branch, when `v_kind.id` is not null:
  - `reason` always required (`reason_required`).
  - `single`: needs `p_start_date`; stored period = that day (`end = start + 1 day`, exclusive); `p_end_date` ignored. `range`: as today's «طلب آخر». `none`: both dates ignored; period = today in the company time zone. Window rule for `single`/`range` is today's (start ≥ today−30, ≤ today+365, span ≤ 365 → else `invalid_dates`).
  - The chain: `private.request_chain(me.company_id, v_type, v_pt.id, case when v_type = 'other' then v_kind.id end)`; the insert stores `custom_kind_id` for `other` too.

- [ ] **Step 1: Write the failing tests** (block 6): `single` with an end date given stores a one-day period; `range` with `end < start` → `invalid_dates`; `none` with null dates is accepted and stores today; all three: no reason → `reason_required`; disabled / other company / leave-family kind errors as in Task 5; start before today−30 or after today+365 → `invalid_dates`; the kind's chain `[hr]` → exactly one approval row, `hr`, pending; kind without a chain, employee with a manager → manager step then hr; employee without a manager → manager step `skipped`, hr pending; **the plain «طلب آخر» of the same employee uses the plain chain even when K has its own chain, and vice versa**; the chain is frozen: editing K's chain after submit leaves the existing `request_approvals` unchanged; flow: the manager approves with `approver_decide` → next step pending; `admin_decide_request` approve → request `approved`, `current_step` null; a rejected one ends `rejected`; `employee_cancel_request` on a pending custom request → `cancelled`; a custom «other» never changes any leave balance; the same key twice → one row.
- [ ] **Step 2: Run the single file.** Expected: FAIL.
- [ ] **Step 3: Implement section F** (edit the section E function text in place; one `create or replace` for the function remains in the migration file, not two).
- [ ] **Step 4: Run** the Task 5 regression slice plus `tests/phase5_notifications_tests.sql`. Expected: `failed=0`.
- [ ] **Step 5: Commit** `feat(db): phase 24 - submit a custom other request with its own chain`.

---

### Task 7: What the app and the people see: request JSON, notification text, final-approval check, overview

**Files:**
- Modify: migration (section G), tests (block 7)

**Interfaces:**
- Changes:
  - `private.request_json(uuid)` — start from the phase 18b text; add keys `custom_kind_id`, `kind_name` (live from the kind) and `date_mode` (the kind's, else null) via `left join public.custom_request_kinds k on k.id = r.custom_kind_id`.
  - `private.request_summary(uuid)` — start from phase 5: a leave with `leave_type = 'custom'` reads `'إجازة ' || k.name`; an other request with a kind reads `k.name` in place of «طلب آخر»; the rest of the line (days, dates) unchanged.
  - `private.apply_decision(uuid, text, text, uuid, boolean)` — start from phase 18a; in the final-approval branch use `private.custom_leave_balance(v_req.employee_id, v_req.custom_kind_id, year, v_req.id)` when `v_req.leave_type = 'custom'`, else the existing call. Nothing else changes (P1).
  - `public.employee_requests_overview()` — start from phase 4d (check that no later migration redefines it: `grep -l "function public.employee_requests_overview" migrations/*.sql`); add key `custom_kinds`: enabled kinds of my company, leave kinds only when `gender = 'all'` or equals my gender, each `{id, family, name, sort_order, gender, reason_required, date_mode, balance}` where `balance` is the Task 3 result for leave kinds and null for other kinds; ordered by `sort_order`, name; `[]` when none (never null). Existing keys unchanged.

- [ ] **Step 1: Write the failing tests** (block 7): `request_json` of a custom leave has `kind_name` = the kind's name, `custom_kind_id`, `leave_type 'custom'`; of a built-in leave and of a plain «طلب آخر» these three keys are null; **renaming the kind changes `kind_name` in an old request**; `date_mode` is returned for a custom other; the notification (`public.notifications`, kind `approval_needed`, and `request_decided` after approval) body contains the kind name for both families; **decision-time re-check (Review Focus 2):** a 3-day custom leave without reason is submitted under default 5, the admin lowers `default_days` to 2, final approval → `insufficient_balance`; the same request submitted with a reason is approved; overview: only enabled kinds, a `female` kind hidden from a male employee and shown to a female one, each leave kind carries the right numbers after one approved and one pending request, an other kind shows `date_mode`, order by `sort_order` then name, kinds of another company absent, `[]` for a company with none, the keys `balances`, `permission_types`, `requests`, `inbox_count`, `timezone`, `today` unchanged.
- [ ] **Step 2: Run the single file.** Expected: FAIL.
- [ ] **Step 3: Implement section G.**
- [ ] **Step 4: Run the full DB suite** `bash local/test-db.sh`. Expected: `TOTAL passed=<1417+new> failed=0`.
- [ ] **Step 5: Commit** `feat(db): phase 24 - kind name in requests and notifications, final-approval check, overview`.

---

### Task 8: Rollback, mutation checks, production fingerprints

**Files:**
- Modify: `…_ROLLBACK.sql` (complete it)
- Create: `/tmp/claude-0/-home-claude/c1150a21-b898-5782-a082-19de101e9dc6/scratchpad/mutate-phase24.sh` (throwaway; not committed)

- [ ] **Step 1: Complete the rollback.** It restores the previous text of `employee_submit_request` (10 arguments, phase 18a), `private.request_chain` (3 arguments, phase 4d), `admin_get_approval_chains` and `admin_set_approval_chain` (phase 4d), `private.request_json` (phase 18b), `private.request_summary` (phase 5), `private.apply_decision` (phase 18a), `employee_requests_overview` (phase 4d), drops the new functions, then section A's undo. Before touching anything it refuses when a request has `custom_kind_id`.
- [ ] **Step 2: Prove it.** On a fresh `waqti_test` with every migration applied: record `md5(prosrc)` of the eight restored functions from a database **without** phase 24 (apply all migrations except `20261111090000_*`), then apply phase 24 and its rollback in one transaction on a second database and compare the eight fingerprints. Expected: all eight equal, no object named `custom_*` left, and a request with `custom_kind_id` makes the rollback stop with `rollback_refused_custom_requests_exist`. Then run the full suite on the rolled-back database. Expected: `TOTAL passed=1417 failed=0` (phase 24 test file excluded).
- [ ] **Step 3: Mutation checks.** For each mutant, copy the migration, change one thing, run the phase 24 file; each must show `failed>0`. At least these 14: gender check removed; `enabled` check removed; kind lookup without the company filter; kind family not compared with `p_type`; `remaining` compared with `<=`; per-employee override ignored; `coalesce(default_days, …)` turned into `coalesce(default_days, 0)`; `request_chain` without `custom_kind_id` match (rows branch); `request_chain` without it (default branch); `customized` not ignoring kind rows; `apply_decision` still calling `private.leave_balance`; `none` date mode using `p_start_date`; `reason_required` ignored for leave kinds; anon grant added to `admin_save_custom_kind`. A surviving mutant gets its own test (RED→GREEN) in the matching block before moving on.
- [ ] **Step 4: Read production fingerprints (read-only).** With `mcp__Supabase__execute_sql` on project `fgnbdlqmtezneznwvahf` run only `select … md5(p.prosrc) … from pg_proc …` for the eight functions that phase 24 replaces. Expected: equal to the local pre-phase-24 values; if any differs, stop and report which one (do not guess).
- [ ] **Step 5: Commit** `feat(db): phase 24 - rollback proven, mutation checks` (the rollback file only).

---

### Task 9: Panel — the «أنواع الطلبات» pane

**Files (panel repo `/home/claude/waqti-admin`):**
- Create: `js/settings/request-kinds.js`, `tests/request-kinds.test.mjs`
- Modify: `js/settings/index.js` (import, and add `requestKindsPane` to `PANES` right after `permissionTypesPane`), `js/core/errors.js` (Arabic text for the six new codes: «يوجد نوع بنفس الاسم», «لا يمكن حذف نوع له طلبات، ألغِ تفعيله», «بلغتَ الحد الأقصى من الأنواع (30)», «النوع غير موجود», «النوع غير مفعّل», «هذا النوع غير متاح لهذا الحساب»), `tests/rpc-inventory.test.mjs` (add the three RPC names to `NEW_RPCS` and fix the counts in the test titles and `assert.equal`), `tests/ui/fake-supabase.js` (handlers `admin_list_custom_kinds`, `admin_save_custom_kind`, `admin_delete_custom_kind` modelled on `admin_list_permission_types`), `tests/ui/behavior.mjs`, `tests/ui/scenario-v12.mjs` (open the new pane in the layout run)

**Interfaces:**
- Produces (exports of `request-kinds.js`): `FAMILY_LABEL = {leave: 'إجازة', other: 'طلب آخر'}`, `GENDER_LABEL = {all: 'الجميع', female: 'نساء فقط', male: 'رجال فقط'}`, `DATE_MODE_LABEL = {single: 'يوم واحد', range: 'فترة (من – إلى)', none: 'بدون تاريخ'}`, `kindRules(kind) → string`, `kindPayload(family, values, existingId) → {args} | {error}`, `requestKindsPane` (`id: 'request-kinds'`, `title: 'أنواع الطلبات'`, `group: 'الموافقات والبيانات'`, `guard: false`), `openKindForm(family, kind, kinds, onSaved)`.
- Consumes: RPCs of Task 2.

- [ ] **Step 1: Write the failing unit tests** (`tests/request-kinds.test.mjs`, `node --test`): `kindRules` — leave with 10 days, `all`, no reason → `10 أيام في السنة`; unlimited (`default_days` null) → text contains `بلا حد`; `0` → `0 يوم` (not unlimited); `female` adds `نساء فقط`; `reason_required` adds `السبب إلزامي`; other kind → the date-mode label only. `kindPayload` — empty days field → `p_default_days: null`, `"0"` → `0`, `"10.5"` → `10.5`, `"367"` / `"-1"` / `"abc"` → `{error: 'invalid_input'}`; name is trimmed, empty → error; family `other` forces `p_gender 'all'`, `p_default_days null`, `p_reason_required false` and needs a date mode; family `leave` forces `p_date_mode null`; `p_id` null for create.
- [ ] **Step 2: Run** `npm test` in the panel folder. Expected: FAIL (module missing).
- [ ] **Step 3: Implement `request-kinds.js`** following `permission-types.js` (table with name + request counts, family badge, rules text, status badge, edit button; «+ إضافة نوع» first opens a small chooser of the family, then the family's form: leave → name, days, gender, reason switch, order, enabled; other → name, date mode, order, enabled; delete button only when `requests_count === 0`, with `window.confirm`). A hint links to the approvals pane for the chain of «other» kinds.
- [ ] **Step 4: Run** `npm test`. Expected: all pass (80 + new).
- [ ] **Step 5: Write the failing behaviour checks** in `tests/ui/behavior.mjs`: the pane is listed under «الموافقات والبيانات»; empty state text; adding a leave kind sends the expected RPC arguments (days empty → null); adding an other kind; `kind_name_taken` from the fake shows its Arabic text and keeps the dialog open; delete is absent for a kind with requests and present (with confirm) for one without; toggling `enabled` saves. Run `node tests/ui/behavior.mjs .`. Expected: FAIL before the pane is wired, pass after (wire `index.js`).
- [ ] **Step 6: Layout run.** `node tests/ui/layout.mjs --dir . --scenario v12 --out tests/ui/shots`. Expected: 0 screens with problems at all three widths, including the new pane and both forms.
- [ ] **Step 7: Checkpoint.** The panel folder `/home/claude/waqti-admin` is **not** a git repository, so there is no commit here. Record the state with the ledger line (test counts) and, at the end of Task 10, the 12.23 zip.

---

### Task 10: Panel — chains, employee days, names everywhere, version 12.23

**Files (panel repo):**
- Modify: `js/settings/approvals.js`, `js/employee-form.js`, `js/requests.js`, `js/lib/leave-text.js`, `export.js`, `package.json` (`12.23.0`), `tests/rpc-inventory.test.mjs` (+ `admin_get_employee_kind_days`, `admin_set_employee_kind_days`), `tests/ui/fake-supabase.js`, `tests/ui/behavior.mjs`
- Create: `tests/kind-names.test.mjs`

**Interfaces:**
- `chainEditor(type, title, initial, customized, permissionTypeId = null, customKindId = null)` — sends `p_custom_kind_id`; the pane draws one editor per `data.custom_kinds` item titled `'طلب آخر: ' + name` (+ ` (غير مفعّل)`).
- `LEAVE_LABEL.custom = 'خاصة'`; `reqTitle(r)` → leave: `'إجازة ' + (r.kind_name || LEAVE_LABEL[r.leave_type] || '')`; other: `r.kind_name || 'طلب آخر'`; `reqPeriod(r)` for `r.date_mode === 'none'` returns the text `بدون تاريخ`.
- Export: `reqDetailText` and the per-type statistics use `r.kind_name` for custom requests instead of `r.leave_type`.

- [ ] **Step 1: Write the failing tests.** `tests/kind-names.test.mjs`: `reqTitle` for a custom leave with a name, a custom leave without a name (`إجازة خاصة`), a custom other, a plain other, a built-in leave; `reqPeriod` for `date_mode 'none'`; the export detail text for a custom leave and a custom other (use the pure helpers in `export.js`; follow how `tests/export.test.mjs` reaches them). Behaviour (`behavior.mjs`): the approvals pane draws a chain editor per custom other kind and saving calls `admin_set_approval_chain` with `p_custom_kind_id`; the employee form of an existing employee shows one days field per enabled leave kind (hidden `female` kind for a male employee, like maternity), shows the placeholder `الافتراضي: N` or `غير محدود`, and on save calls `admin_set_employee_kind_days` **only with the changed keys** (empty → null, `0` → 0) and not at all when nothing changed; the create form shows the hint and no fields.
- [ ] **Step 2: Run** `npm test` and `node tests/ui/behavior.mjs .`. Expected: FAIL.
- [ ] **Step 3: Implement** the changes above. In `employee-form.js` load kinds with `admin_list_custom_kinds` and overrides with `admin_get_employee_kind_days` next to the existing profile load, and call the setter right after `admin_save_employee_profile` succeeds.
- [ ] **Step 4: Run** `npm test`, `node tests/ui/behavior.mjs .`, the layout command. Expected: all pass, 0 layout problems.
- [ ] **Step 5: Package** with `scripts/pack.py` (read its header for the arguments; it produced `waqti_admin_12_22.zip`), output `waqti_admin_12_23.zip` beside the earlier zips in `/home/claude/out`. Expected: the zip lists `js/settings/request-kinds.js` and `package.json` shows `12.23.0`. No git commit (the folder is not a repository); the zip is the record.

---

### Task 11: App — types, helpers, errors, mock (unit-tested)

**Files (repo `/home/claude/waqti-app`):**
- Modify: `src/lib/types.ts`, `src/lib/requests.ts`, `src/lib/errors.ts`, `src/lib/mockApi.ts`, `src/lib/requests.test.ts`

**Interfaces:**
- `types.ts`: `LeaveType` gains `"custom"`; `export type DateMode = "single" | "range" | "none"`; `export interface CustomKind { id: string; family: "leave" | "other"; name: string; sort_order: number; gender: "all" | "female" | "male"; reason_required: boolean; date_mode: DateMode | null; balance: LeaveBalance | null }`; `RequestsOverview.custom_kinds?: CustomKind[]` (optional: an older database omits it); `RequestItem` gains `custom_kind_id?: string | null; kind_name?: string | null; date_mode?: DateMode | null`; the `leave` and `other` variants of `NewRequest` gain `custom_kind_id?: string | null`.
- `requests.ts`: `LEAVE_LABEL.custom = "خاصة"`; `requestTitle` prefers `kind_name` (leave: `إجازة ${kind_name}`; other: `kind_name`); `Draft.custom_kind_id: string` (`""` = none); `emptyDraft` sets it `""`; `customKindsOf(o: Pick<RequestsOverview, "custom_kinds">, family: "leave" | "other"): CustomKind[]` (empty array when missing); `draftToRequest(d, timeZone, kinds?: CustomKind[])` — with a leave kind: `leave_type: "custom"`, `custom_kind_id`, and `reason_required` (error `reason_required` when the kind needs one and the reason is empty); with an other kind: `date_mode single` sends `end_date = start_date`, `none` sends `start_date = end_date = d.start_date`, the reason is required as today; `submitArgs` adds `p_custom_kind_id: r.type === "permission" ? null : (r.custom_kind_id ?? null)`.
- `errors.ts`: the codes `custom_kind_not_found`, `custom_kind_disabled`, `kind_gender_mismatch` in the union and in the server-code list, with texts «هذا النوع لم يعد متاحاً.», «هذا النوع متوقف حالياً.», «هذا النوع غير متاح لهذا الحساب.».
- `mockApi.ts`: the overview returns two custom kinds (a leave kind with a balance, an other kind with `date_mode "single"`); `submitRequest` stores `custom_kind_id` and `kind_name` and, for a custom leave, computes the balance from the kind.

- [ ] **Step 1: Write the failing tests** in `requests.test.ts`: `requestTitle` with and without `kind_name`; `customKindsOf` for a missing key, per family; `draftToRequest` for a custom leave (fields as above, `reason_required` error, empty reason fine otherwise), custom other `single` / `none` / `range`, a plain other unchanged, a built-in leave unchanged (`custom_kind_id` absent); `submitArgs` has `p_custom_kind_id` for a custom leave and a custom other and `null` for the built-ins and for permissions; the three error codes have non-empty Arabic text.
- [ ] **Step 2: Run** `npm test`. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** `npm test` and `npm run typecheck`. Expected: all green (previous count + new), no type errors.
- [ ] **Step 5: Commit** (local) `feat(app): custom request kinds - types, helpers, mock`.

---

### Task 12: App — the request form and lists

**Files:**
- Modify: `src/screens/Requests.tsx`

**Interfaces:**
- Consumes: Task 11. No new exports.

Behaviour:
  - Leave form: the type `<select>` keeps the six built-ins first, then an `<optgroup label="إجازات أخرى">` with the custom leave kinds; option values are the built-in key or `custom:<id>`; choosing a custom kind sets `leave_type: "custom"` and `custom_kind_id`; the balance line under the select uses the kind's `balance`; the reason label reads «السبب (مطلوب)» when the kind requires it.
  - «طلب آخر»: when custom other kinds exist, a select appears with «طلب آخر» first and the kinds after; dates follow the kind's mode (`single`: one date field labelled «التاريخ»; `none`: no date fields; `range`: as now). With no custom kinds the form is exactly today's.
  - Balances block: custom leave kinds with `used + pending > 0` join the "other types" line as `name: N هذه السنة`.
  - Request cards and details: titles from `requestTitle` (kind name); the period line is replaced by nothing for `date_mode "none"`.

- [ ] **Step 1: Implement** the behaviour. Check that `draft.custom_kind_id` is reset when the type switches and that `clampLeaveDates` still applies to custom leaves.
- [ ] **Step 2: Run** `npm test`, `npm run typecheck`, `npm run build`. Expected: all pass.
- [ ] **Step 3: Look at it.** Start the app in its mock mode (see `README.md` for the flag), open the request form at 390 px width with Playwright (Chromium is installed; `deviceScaleFactor: 2`) and take screenshots of: a custom leave selected (balance line visible), a custom other with `single`, one with `none`, the plain «طلب آخر», and the request list with a custom item. Expected: right-to-left, no horizontal scroll, no clipped text. Save the screenshots in the scratchpad, not in the repo.
- [ ] **Step 4: Commit** (local) `feat(app): request form and lists understand custom kinds`.

---

### Task 13: Documents and the final run

**Files:**
- Create: `docs/PHASE24_RUN_LOCALLY.md`
- Modify: `docs/API_CONTRACT.md` (new §12), `CHANGELOG.md`, the spec if any ruling changed

- [ ] **Step 1: Final runs.** DB: `bash local/test-db.sh` → note `TOTAL passed=<N> failed=0`. Panel: `npm test`, `node tests/ui/behavior.mjs .`, the layout command → note the counts. App: `npm test`, `npm run typecheck`, `npm run build` → note the counts. Expected: everything green.
- [ ] **Step 2: Fingerprints.** On the final local database record `md5(prosrc)` of every function the migration creates or replaces (list from the migration), and the group fingerprint (`md5(string_agg(md5(prosrc), '' order by proname))`), as `PHASE23_RUN_LOCALLY.md` does.
- [ ] **Step 3: Write `docs/PHASE24_RUN_LOCALLY.md`** in the same shape as phase 23's: what it does; how to run the DB tests; the other test commands and their last counts; how to apply later (needs Omar's «نعم» for «طبّق المرحلة 24»): apply the migration in one call, compare fingerprints, check grants and RLS, install panel 12.23, then the app build — **order: migration, panel, app**; the production pre-apply fingerprints of Task 8 step 4; the rulings P1–P5 with what each costs if wrong; the rollback and how it was proven.
- [ ] **Step 4: Write `API_CONTRACT.md` §12** (the new RPCs with arguments, return shapes, error codes; the changed `employee_submit_request` 11th argument; the new `custom_kinds` key of the overview and `custom_kind_id`/`kind_name`/`date_mode` keys of a request) and a `CHANGELOG.md` entry.
- [ ] **Step 5: Commit** `docs: phase 24 - run guide, API contract, changelog` (local). Do not push.
