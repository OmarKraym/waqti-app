# Phase 1 — Attendance rules (lateness rule, justification offer, deduction engine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** the server decides who is late and by how much (grace + a company rule), offers the late-arrival justification only when it can really be used, and computes a late deduction from a dated company policy (proportional or tiers).

**Architecture:** three migrations (19a rule, 19b deduction engine + attendance-list columns, 19c late status + request-limit guard), each with a ROLLBACK and a test file in the local Postgres suite. Admin panel 12.16.0 (settings panes + attendance column). App: the post-punch offer moves from "preview the request" to one server call `employee_late_status`. Nothing is blocked: a punch is never refused because of lateness.

**Tech Stack:** Postgres/Supabase SQL (`supabase/local/test-db.sh`), React+Vite+TS (vitest, Playwright mock mode), admin panel plain ES modules (`/home/claude/waqti-admin`, outside the repo).

**Spec:** `docs/superpowers/specs/2026-11-08-waqti-modernization-design.md` §2 Phase 1 (1أ, 1ب, 1ج).

## Global Constraints

- No push, no deploy, nothing applied to production without Omar's explicit «نعم» for this phase. Migrations are delivered, not applied. No `service_role`. Admin panel stays outside the repo (zip).
- Every new function: `security definer`, `set search_path = ''` (public admin functions keep `'public'` like phase 12), company taken from `require_company_admin()` / `require_active_employee()`, revoked from `public, anon`, granted to `authenticated` (private ones: revoked from all). New tables: RLS on, no grants to `anon, authenticated`.
- Every admin write calls `public.audit_write(company, action, entity, id, details)`.
- Start from the LATEST text of what is replaced: `private.punch_lateness` and `admin_list_attendance` (both phase 12, `20261102140000_phase12_grace_period.sql`), `employee_submit_request` (phase 18a, only read, not replaced).
- Existing behaviour is the default: `late_rule = 'all_after_grace'`; all phase 12 tests still pass unchanged.
- Arabic RTL UI, short plain text. Error codes follow the existing style (`invalid_settings` 22023, `permission_limit` P0001, …).
- Migrations: `20261108100000_phase19a_late_rule.sql`, `20261108110000_phase19b_deduction_policies.sql`, `20261108120000_phase19c_late_status.sql` (+ `_ROLLBACK.sql` each). Guard block at the top of each (expected functions exist, previous phase applied).

## Rulings (the spec is silent or ambiguous)

- R1 Omar's «go» = option A: the current rule stays the default; `beyond_grace` is a company setting.
- R2 One `late_rule` setting applies to late arrival AND early leave (the grace pane already treats them as a pair).
- R3 A deduction is in **minutes of pay**, not currency; turning minutes into money belongs to payroll (not in this phase).
- R4 A policy is editable/deletable only while `effective_from >= company today`; older ones are locked history. A new policy applies from its date on; earlier days keep the policy that was in force.
- R5 A late arrival is fully excused only by an **approved** late-arrival justification with `end_at >= arrival time`. A pending one makes the deduction `pending` (shown as provisional). A rejected/cancelled one counts as none.
- R6 `employee_late_status` answers for the caller's own first check-in of a local day; any other event → `offer=false` with a reason code. The employee also sees the expected deduction (hiding it per employee is Phase 5).
- R7 `max_minutes` of the justification type is checked as today (shift start → arrival, raw minutes). Longer → `reason='too_long'`, no offer (the submit would fail anyway).
- R8 The monthly limit is enforced again by a `before insert` trigger on `public.requests` (advisory lock per employee), because check-then-insert in `employee_submit_request` can let two parallel requests pass.

## Review Focus

- Arrival exactly at the grace edge (shift 08:00, grace 15: 08:15 → 0, 08:16 → 16 under A, 1 under B).
- Employee with a personal grace value (employees.late_grace_min) overriding the company value, under both rules.
- A day off, or a second check-in of the day: no lateness, no offer.
- Two parallel justification requests with 1 left: exactly one succeeds.
- Policy dated in the future, then changed to today's date: past days never change.
- Tiers with a gap or overlap, `to` smaller than `from`, non-integer values: rejected, nothing saved.
- A justification approved for an earlier time than the real punch: not excused.
- Offline punch synced later: `employee_late_status` still answers for that event; the app offers only if still online.

---

### Task 1: Late rule setting (migration 19a)

**Files:**
- Create: `supabase/migrations/20261108100000_phase19a_late_rule.sql`, `…_ROLLBACK.sql`, `supabase/tests/phase19a_late_rule_tests.sql` (run it with `TESTS=…`; the default list in `test-db.sh` is extended in Task 7)

**Interfaces:**
- Produces: column `companies.late_rule text not null default 'all_after_grace' check (late_rule in ('all_after_grace','beyond_grace'))`; `private.punch_lateness(uuid, uuid, text, timestamptz) returns integer` (same signature, rule-aware); `public.admin_get_grace_settings() returns jsonb` now also `late_rule`; `public.admin_set_late_rule(p_rule text) returns jsonb` (same shape as the getter, audit action `company.late_rule`).

- [ ] **Step 1: Write the failing test** `phase19a_late_rule_tests.sql` (same harness as `phase12_grace_period_tests.sql`: shift 08:00–16:00 for one employee, company grace 15/10). Assertions: default rule is `all_after_grace` and the phase 12 values are unchanged (08:15 → 0, 08:16 → 16, 08:30 → 30; last out 15:50 → 0, 15:49 → 11); after `admin_set_late_rule('beyond_grace')` the same punches give 0, 1, 15 and 0, 1; the employee's own grace (e.g. 5) overrides the company's under both rules; check-out follows the same rule; a day off and a second check-in stay `null`; `admin_set_late_rule('x')` and `null` → `invalid_settings`; an employee (non-admin) calling it is refused; admin A's change leaves a second company (inserted by the test) on `all_after_grace`; one `audit_log` row with action `company.late_rule`; `admin_get_grace_settings()` includes `late_rule`.
- [ ] **Step 2: Run it, expect FAIL** — `su postgres -c "TESTS=tests/phase19a_late_rule_tests.sql bash supabase/local/test-db.sh"`. Expected: `NO RESULT` or FAIL "column late_rule does not exist" (the migration is missing).
- [ ] **Step 3: Write the migration** (guard; add column; `create or replace` `private.punch_lateness` with the phase 12 body, last line becomes: `v_min <= v_grace → 0`, `beyond_grace → v_min - v_grace`, else `v_min`; read `late_rule` with the company row; replace the getter; add the setter; grants). Write the ROLLBACK (restore phase 12 bodies, drop column).
- [ ] **Step 4: Run phase 19a and phase 12 tests, expect all PASS** — `TESTS="tests/phase19a_late_rule_tests.sql tests/phase12_grace_period_tests.sql"`.
- [ ] **Step 5: Rollback round trip** — script like `/tmp/rb18b.sh`: fingerprint → apply ROLLBACK (column gone, phase 12 tests pass) → re-apply → fingerprint equal. Mutant: make the setter skip the rule check; the invalid-rule test must fail.
- [ ] **Step 6: Commit** `git add supabase/migrations/20261108100000_* supabase/tests/phase19a_*` — "Late rule: grace counted in full or only beyond it (phase 19a)".

---

### Task 2: Deduction engine (migration 19b, part 1: tables and functions)

**Files:**
- Create: `supabase/migrations/20261108110000_phase19b_deduction_policies.sql`, `…_ROLLBACK.sql`, `supabase/tests/phase19b_deduction_policies_tests.sql`

**Interfaces:**
- Consumes: Task 1 `companies.late_rule`, `late_grace_min`.
- Produces:
  - table `public.deduction_policies(id uuid pk, company_id uuid not null → companies, effective_from date not null, kind text check in ('proportional','tiers'), params jsonb not null, created_by uuid, created_at timestamptz, unique(company_id, effective_from))`, RLS on, no grants.
  - `params` for `proportional`: `{"per_minutes":1..240,"deduct_minutes":0..1440,"round_to":1|5|10|15|30|60,"rounding":"up"|"down"|"nearest"}`; for `tiers`: `{"tiers":[{"from":int>=1,"to":int>=from|null,"deduct":int 0..1440}]}` sorted, no gap or overlap, only the last `to` may be null.
  - `private.deduction_params_ok(p_kind text, p_params jsonb) returns boolean` (immutable).
  - `private.deduction_calc(p_kind text, p_params jsonb, p_chargeable integer) returns integer` (immutable): ≤0 → 0; proportional = `round_dir(chargeable * deduct_minutes / per_minutes / round_to) * round_to`; tiers = deduct of the tier that contains `chargeable`, 0 if none.
  - `private.late_deduction(p_company uuid, p_day date, p_chargeable integer) returns integer`: policy with the greatest `effective_from <= p_day`, none → 0.
  - `public.admin_list_deduction_policies() returns jsonb` (array, newest first, each with `editable` boolean = `effective_from >= company today`).
  - `public.admin_save_deduction_policy(p_id uuid, p_effective_from date, p_kind text, p_params jsonb) returns jsonb` (p_id null = new; `invalid_settings` for bad params, `policy_locked` P0001 for a past policy, `policy_date_taken` for a duplicate date; audit `company.deduction_policy`).
  - `public.admin_delete_deduction_policy(p_id uuid) returns void` (`policy_locked` if past; audit).
  - `public.admin_preview_deduction(p_policy jsonb, p_late_after_start integer[]) returns jsonb` (`p_policy` = `{"kind":…,"params":…}`): for each value → `{late, chargeable, deduct}` using the company's grace and `late_rule` (so «09:15 ← 0, 09:16 ← 12» is shown from real settings).

- [ ] **Step 1: Write the failing test** — `deduction_calc` table: proportional `per=15,deduct=10,round_to=5` (nearest/up/down) for 1, 7, 8, 15, 16, 30, 31; `round_to=1` with 1:1 returns the input; tiers `[1–15→0, 16–30→30, 31–null→60]` for 0, 1, 15, 16, 30, 31, 600; chargeable 0 and null → 0. `deduction_params_ok` rejects: a tier gap (15 then 17), overlap, `to < from`, non-integer, negative deduct, open `to` in the middle, `round_to=7`, `per_minutes=0`. `late_deduction`: two policies dated D-10 and D+5 → day D-3 uses the first, D+5 uses the second, a day before the first → 0, no policy → 0; re-dating the future policy to today leaves the result for D-3 unchanged. Admin: save/list/delete; editing a policy dated yesterday → `policy_locked`; today's date is editable; duplicate date → `policy_date_taken`; an employee and a second company's admin cannot list or change this company's rows (insert company B's policy directly as superuser); preview returns the same numbers as `deduction_calc` for grace 15 under both rules; one audit row per write.
- [ ] **Step 2: Run, expect FAIL** (relation `deduction_policies` does not exist).
- [ ] **Step 3: Write the migration + ROLLBACK** (the three `admin_*` functions plus preview; grants; `deduction_calc` is the only place the formula lives, preview and list call it).
- [ ] **Step 4: Run, expect PASS**; **Step 5:** rollback round trip + mutant (change `round up` to `down` in the migration: the rounding rows must fail).
- [ ] **Step 6: Commit** — "Deduction policies: proportional or tiers, dated, one calculation function (phase 19b)".

---

### Task 3: Deduction in the attendance list (migration 19b, part 2)

**Files:**
- Modify: `supabase/migrations/20261108110000_phase19b_deduction_policies.sql` (+ its ROLLBACK), `supabase/tests/phase19b_deduction_policies_tests.sql`

**Interfaces:**
- Consumes: Task 2 `private.late_deduction`.
- Produces: `private.punch_deduction(p_employee uuid, p_event uuid, p_at timestamptz) returns jsonb` → `{"minutes":int,"state":"none"|"due"|"pending"|"excused"}` (R5); `public.admin_list_attendance(...)` keeps every phase 12 column and adds `deduction_minutes integer, deduction_state text` at the end (null for check-outs).

- [ ] **Step 1: Failing tests** — approved justification with `end_at` = arrival → `excused`, 0; approved with `end_at` 10 minutes before arrival → `due` (R5); pending → `pending` with the provisional minutes; rejected → `due`; chargeable 0 → `none`; check-out rows → null; no policy → `none`; list columns keep their order and values for phase 12 tests.
- [ ] **Step 2: Run, expect FAIL** → **Step 3:** guard that the current return type ends with `early_minutes integer`; drop and recreate `admin_list_attendance` (phase 12 text + two columns); ROLLBACK recreates the phase 12 version. **Step 4:** run 19b + phase 12 + phase 8b tests, expect PASS. **Step 5:** commit "Attendance list shows the late deduction and its state".

---

### Task 4: Late status for the employee + request-limit guard (migration 19c)

**Files:**
- Create: `supabase/migrations/20261108120000_phase19c_late_status.sql`, `…_ROLLBACK.sql`, `supabase/tests/phase19c_late_status_tests.sql`, `supabase/local/concurrency-limit.sh`

**Interfaces:**
- Consumes: Tasks 1–2 (`punch_lateness`, `late_deduction`), `private.permission_usage`, `private.shift_bounds`.
- Produces: `public.employee_late_status(p_event_id uuid) returns jsonb`:
  `{"event_id", "late_min": raw minutes after shift start (0 if none), "grace_min", "chargeable_min", "deduction_min": int|null (null = no policy), "rule": "all_after_grace"|"beyond_grace", "remaining": int|null (null = no monthly limit), "offer": boolean, "reason": "offer"|"not_late"|"within_grace"|"day_off"|"not_first"|"not_check_in"|"no_type"|"no_balance"|"already"|"too_long", "permission": <private.permission_usage json of the late-arrival type> | null}`. Errors: `event_not_found` (not the caller's), `not_authenticated`.
  `offer` is true only when `chargeable_min > 0` and a late-arrival type is active and `remaining` is null or > 0 and no pending/approved justification exists for that day and `late_min <= max_minutes`.
  Trigger `private.requests_limit_guard()` `before insert on public.requests when (new.request_type = 'permission' and new.status = 'pending')`: `pg_advisory_xact_lock(hashtextextended('waqti.perm:' || new.employee_id::text, 0))`, then re-reads `private.permission_usage` for the month of `new.start_at` and raises `permission_limit` (P0001) when `max_per_month` is reached.

- [ ] **Step 1: Failing tests** (shift 08:00, grace 15, limit 3): 08:15 → `within_grace`; 08:16 → `offer` with `chargeable_min` 16 (A) / 1 (B), `remaining` 3; used 1 + pending 1 → `remaining` 1, offer; used 3 → `no_balance`, no offer; `max_per_month` null → `remaining` null, offer; pending or approved for that day → `already`, a rejected one → offer; raw 70 with `max_minutes` 60 → `too_long`; no active late-arrival type → `no_type`; day off → `day_off`; second check-in → `not_first`; a check-out event → `not_check_in`; another employee's event → `event_not_found`; with a policy, `deduction_min` equals `private.late_deduction`; an employee with personal grace 30 punching 08:20 → `within_grace`; an offline-synced check-in (`metadata.offline = true`, `created_at` hours after `occurred_at`) gets the same answer as an online one. Guard: with limit 1, a direct second pending insert (bypassing the function) → `permission_limit`; approved/rejected inserts are not blocked; the first insert passes.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the migration + ROLLBACK** (function, trigger function, trigger; grants: function to `authenticated` only).
- [ ] **Step 4: Run, expect PASS.** `concurrency-limit.sh`: two background `psql` sessions call `employee_submit_request` for a limit-1 type, the first holding its transaction open with `pg_sleep(2)` after the insert; expected output `1 success, 1 permission_limit`. **Mutant:** drop the trigger → the script reports `2 success` (must be seen failing once).
- [ ] **Step 5:** rollback round trip; **Step 6:** commit "Late status for the employee and a race-proof monthly limit (phase 19c)".

---

### Task 5: Admin panel 12.16.0

**Files (in `/home/claude/waqti-admin`):**
- Modify: `js/settings/grace.js` (rule choice), `js/settings/index.js` (+ pane), `js/attendance.js` (deduction cell), `js/lib/minutes.js`, `styles/components.css`, `index.html`, `package.json` (12.16.0), `README.md`, `tests/rpc-inventory.test.mjs` (5 new RPC names: `admin_set_late_rule`, `admin_list_deduction_policies`, `admin_save_deduction_policy`, `admin_delete_deduction_policy`, `admin_preview_deduction`; `employee_late_status` is app-only), `tests/ui/fake-supabase.js`, `tests/ui/scenario-v12.mjs`, `tests/ui/behavior.mjs`
- Create: `js/settings/deductions.js` (pane id `deductions`, group `الدوام`, title «سياسة الخصم»), `js/lib/deduction.js`, `tests/deduction.test.mjs`

**Interfaces:**
- Produces (`js/lib/deduction.js`, pure): `policyArgs(form) → {ok:true,args:{p_id,p_effective_from,p_kind,p_params}}|{ok:false,error}` (client check mirrors R4 limits, the server stays the authority); `describePolicy(policy) → string` (one line, Arabic); `deductionCell(row) → {text, cls}|null` using `deduction_minutes` and `deduction_state` («خصم 12 د»، «مبدئي»، «معفى»); `RULE_LABEL = {all_after_grace, beyond_grace}`; `PREVIEW_LATE = [0,5,10,15,16,20,30,45,60,90]`.

- [ ] **Step 1: Failing unit tests** `tests/deduction.test.mjs`: `policyArgs` (proportional ok; tiers from rows; missing date, `to < from`, a gap, non-number → `{ok:false}` with a message); `describePolicy` both kinds; `deductionCell` for `due`/`pending`/`excused`/`none`/null. Run `npm test`, expect FAIL (module missing).
- [ ] **Step 2: Implement `js/lib/deduction.js`**, run `npm test`, expect PASS.
- [ ] **Step 3: Panes.** `grace.js`: a two-option choice «تُحسب كل الدقائق بعد السماح (الحالي)» / «تُحسب الدقائق بعد السماح فقط», saved with `admin_set_late_rule`; text under it explains both with the 08:16 example. `deductions.js`: list of policies (date, kind, summary, edit/delete only when `editable`), a form (date, kind switch, proportional fields or tier rows with add/remove), and a preview table filled by `admin_preview_deduction(PREVIEW_LATE)` on every change; a missing-function notice like `grace.js`. `attendance.js`: add the deduction beside the late badge.
- [ ] **Step 4: UI tests.** Extend `fake-supabase.js` and `scenario-v12.mjs` (policy list with one locked and one editable row, rule choice, attendance rows with each state); `behavior.mjs` section 19: switching the rule calls `admin_set_late_rule`; saving a bad tier shows the message and calls nothing; a locked policy has no edit button; preview refreshes. Run `node tests/ui/behavior.mjs .` (all pass) and `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir>`: 0 problems on all sizes.
- [ ] **Step 5:** bump version everywhere (`index.html`, `package.json`), README section, `npm test` all green; pack `python3 scripts/pack.py /tmp/zipwork` → `/home/claude/out/waqti_admin_12_16.zip` (not sent until Task 7).

---

### Task 6: Employee app — offer from the server

**Files (in `/home/claude/waqti-app`):**
- Modify: `src/lib/types.ts`, `src/lib/api.ts`, `src/lib/supabaseApi.ts`, `src/lib/mockApi.ts`, `src/lib/lateOffer.ts`, `src/lib/lateOffer.test.ts`, `src/lib/supabaseApi.test.ts`, `src/screens/Main.tsx`, `docs/API_CONTRACT.md`

**Interfaces:**
- Consumes: Task 4 `employee_late_status`.
- Produces: `LateStatus` type (fields exactly as Task 4); `Api.getLateStatus(eventId: string): Promise<LateStatus | null>` (null when the server does not have the function yet or offline); `lateOfferFrom(status: LateStatus, punchIso: string, timeZone: string): LateOffer | null` where `LateOffer = { draft: Draft; minutes: number; left: number | null }` (`minutes = chargeable_min`, `left = remaining`); `lateNote(status: LateStatus): string | null` (one Arabic line for the reasons `no_balance`, `too_long`, `already`; null otherwise and when `chargeable_min = 0`, optionally with the expected deduction when `deduction_min > 0`).
  `shouldAskLateStatus(result: PunchResult): boolean` — false for a duplicate, a check-out and `recorded_offline`; true otherwise.
- `lateCandidate` is removed (its tests move to `lateOfferFrom`); the monthly count is no longer decided in the app.

- [ ] **Step 1: Failing tests** `lateOffer.test.ts`: `lateOfferFrom` returns a draft `{type:"permission", permission_type_id, permission_mode:"late_arrival", date, to:"08:40"}` for an offer; null for every other reason; `left` mirrors `remaining`; `lateNote` strings per reason; `shouldAskLateStatus` (duplicate / check-out / offline → false, online check-in → true); `supabaseApi.test.ts`: `getLateStatus` calls rpc `employee_late_status` with `p_event_id` and returns null when the function is missing. Run `npx vitest run`, expect FAIL.
- [ ] **Step 2: Implement** the types, API (real + mock: the mock computes the same fields from its permission types and a configurable grace), `lateOffer.ts`; **Step 3:** `Main.tsx` `onPunched`: `if (!shouldAskLateStatus(result)) return;` then `status = await api.getLateStatus(result.event_id)`; show the dialog only when `status.offer`; otherwise show `lateNote` as a dismissible line above the tabs; never throws into the punch flow.
- [ ] **Step 4: Verify** — `npx vitest run` all pass (was 337 + new), `npx tsc -b`, lint; Playwright in mock mode (`VITE_MOCK=1 npx vite --port 5179`, script like `p2-ui.cjs`): late punch with balance → dialog with «تقديم تبرير»; with no balance → note line, no dialog; within grace → nothing. Screenshots at 360×740.
- [ ] **Step 5: Commit** — "Late justification offered from the server's decision (phase 19c, app)".

---

### Task 7: Verification, docs, hand-off

**Files:** Create `CHANGELOG.md` (repo root; first entry = phase 19), `docs/PHASE19_RUN_LOCALLY.md`; modify `docs/API_CONTRACT.md` (functions of 19a–c).

- [ ] **Step 1: Full DB suite** — `su postgres -c "bash supabase/local/test-db.sh"` with the default list extended by the three new files; expect `TOTAL … failed=0` (previous total 791 + new). If the phase 14 test fails after ~20:00 local, rerun with libfaketime as before and say so.
- [ ] **Step 2: Everything else** — `npm test` (panel), `node tests/ui/behavior.mjs .`, layout run, app `npx vitest run` and `npx tsc -b`. Record real counts.
- [ ] **Step 3: Docs** — CHANGELOG entry (what changed, files, rollback names, risks: report numbers change only if the company switches to `beyond_grace`), run-locally steps, the order to apply the migrations on production when approved (19a → 19b → 19c, each verified by fingerprint), backup advice first.
- [ ] **Step 4: Commit locally** (no push). Send Omar the panel zip and a short report: counts, what was NOT done (no apply, no deploy, no push), the «نعم» question for applying 19a–c.
