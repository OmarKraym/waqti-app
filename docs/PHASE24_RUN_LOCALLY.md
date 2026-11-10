# Phase 24 — request types the admin adds himself (new leave types, new «طلب آخر» types): run it locally, and how to apply it later

One migration (`supabase/migrations/20261111090000_phase24_custom_request_kinds.sql`, rollback `…_ROLLBACK.sql`), admin panel **12.23.0**, and the employee app (new request form). **Nothing of phase 24 is applied to production, deployed or pushed.**

What it does: the admin adds **new leave types** (days per year with a general default and an override per employee, who may see it: everyone / women / men, reason required or not) and **new «طلب آخر» types** (own approval path, date asked as one day / a period / not at all). Existing requests and types stay as they are; the six built-in leave types, the permission types and the plain «طلب آخر» are not touched. Out of scope: attachments, a field builder, parallel or delegated approvals, a wider rules engine. Spec: `docs/superpowers/specs/2026-11-09-custom-request-kinds-design.md`; plan: `docs/superpowers/plans/2026-11-10-custom-request-kinds.md`; contract: `docs/API_CONTRACT.md` §12.

## 1. Run the database tests (local only)
```bash
cd supabase
PGDATABASE=postgres bash local/test-db.sh                                                    # every file, each on a fresh database: TOTAL passed=1660 failed=0
PGDATABASE=postgres TESTS=tests/phase24_custom_request_kinds_tests.sql bash local/test-db.sh  # only phase 24 (243 assertions)
```
Same setup as phase 23 (Postgres 16 + PostGIS, libfaketime). **Two things about the local clock** (tests of older phases depend on the time of day, not on phase 24): the full suite passes only when the local server clock starts between 12:00 and 13:00 on Saturday 2026-10-31 (Tripoli) — it was run at 12:05; phase 15 needs the clock after noon, phase 23's 240-minute grace needs it before 13:00. The phase 24 file itself is time-insensitive. One run at a time: the runner always rebuilds the database `waqti_test`.

## 2. Other tests (last run 2026-11-10)
| What | Command | Last run |
|---|---|---|
| Database, whole suite | see §1 | 33 files, TOTAL passed=1660 failed=0 |
| Database, rolled back | the migration + its rollback, then the suite with the pre-phase-24 `phase4` test file (the new one names the 11-argument function the rollback removes) | 1367 + 50 = 1417 passed, 0 failed (§5) |
| Migration mutation checks | 21 mutants of the migration (gender / enabled / company / family checks removed, `remaining` compared with `<=`, per-employee days ignored, unlimited turned into 0, the chain without the kind match ×3, final approval still on the built-in balance or not checked, the two date modes, reason rule, `anon` may save a kind, overview showing wrong-gender or disabled kinds, summary without the kind name, pending not counted, a kind in use deletable) | 21 / 21 killed |
| Admin panel, unit | `npm test` (panel folder) | 106 / 106 |
| Admin panel, behaviour | `node tests/ui/behavior.mjs .` | 518 passed, 0 failed |
| Admin panel, layout (every screen, 5 widths) | `node tests/ui/layout.mjs --dir . --scenario v12 --out <dir>` | 348 screens, 0 with problems, 0 issues, 0 script errors |
| App, unit | `npm test` (app folder) | 423 / 423 (27 files) |
| App, types and build | `npm run typecheck`, `npm run build` | clean; built, 36 precache entries |
| App, request form at 390 px (mock mode, Playwright, dpr 2) | `VITE_MOCK=1 npm run dev`, URL flags `?requests=1&inbox=0`; `&kinds=0` plays a database before phase 24 | 41 checks passed: right-to-left, no horizontal scroll, kinds in the lists, one day / no date modes, sent and listed, older database = today's form, no console errors |

## 3. How to apply it later (needs Omar's fresh «نعم» — the answer to «طبّق المرحلة 24»)
**Order: migration first, panel second, app third.** Deploying the panel or the app is a separate step that needs «انشر».
1. Apply the migration with `apply_migration` (one call, the exact file text). The file has **no backslash** (checked with grep), so nothing is lost in the tool call. Production's migration history lacks the 18a/18b names although their functions exist: compare **function fingerprints**, not migration names.
2. Compare each function with the local text:
```sql
select p.oid::regprocedure::text, md5(p.prosrc), p.prosecdef, p.provolatile, coalesce(array_to_string(p.proconfig, ','), '')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where (n.nspname || '.' || p.proname) in ('private.apply_decision','private.custom_leave_balance','private.request_chain','private.request_json',
  'private.request_summary','public.admin_delete_custom_kind','public.admin_get_approval_chains','public.admin_get_employee_kind_days',
  'public.admin_list_custom_kinds','public.admin_save_custom_kind','public.admin_set_approval_chain','public.admin_set_employee_kind_days',
  'public.employee_requests_overview','public.employee_submit_request')
order by 1;
```

| Function | `md5(prosrc)` | security definer / volatility |
|---|---|---|
| `private.apply_decision(uuid,text,text,uuid,boolean)` | `c868c6777046324ef7cf7a8dc8f95bf9` | yes / volatile |
| `private.custom_leave_balance(uuid,uuid,integer,uuid)` | `4e8f07280c05622f31162107a0c3793b` | yes / stable |
| `private.request_chain(uuid,request_type,uuid,uuid)` | `625eace4e2cdee2d603246e4b2480d59` | yes / stable |
| `private.request_json(uuid)` | `236c83e91af09d23bc7366704ed37031` | yes / stable |
| `private.request_summary(uuid)` | `6a25385c316c32caebc4eb4bfdd83d22` | yes / stable |
| `public.admin_delete_custom_kind(uuid)` | `77c7bd1de2336cc6b3733c2a2b365264` | yes / volatile |
| `public.admin_get_approval_chains()` | `c17667055be38dac4a257787e596aec5` | yes / stable |
| `public.admin_get_employee_kind_days(uuid)` | `072596f57b2da0ec7f30094441c9436e` | yes / stable |
| `public.admin_list_custom_kinds()` | `7418d74362b1d16165a7c5658645aa8f` | yes / stable |
| `public.admin_save_custom_kind(uuid,text,text,boolean,numeric,text,boolean,text,integer)` | `8d64bda22e7fec504a15ecfbd17bcb3e` | yes / volatile |
| `public.admin_set_approval_chain(text,jsonb,uuid,uuid)` | `691bf31d4836a9a29d1db34412e86f3d` | yes / volatile |
| `public.admin_set_employee_kind_days(uuid,jsonb)` | `a6c6e16290aef717045c6e190f413578` | yes / volatile |
| `public.employee_requests_overview()` | `69c409442107d17ed438b4ed3c4438e2` | yes / stable |
| `public.employee_submit_request(uuid,text,text,date,date,timestamptz,timestamptz,text,boolean,uuid,uuid)` | `a163495086e2caec0dc6291a67cc248b` | yes / volatile |

   Group fingerprint (`md5(string_agg(md5(prosrc), '' order by proname))` over those fourteen): **`45a70c2b4681bd4d25489065ffc567e5`**. The three overloads that existed before (`request_chain` with 3 arguments, `admin_set_approval_chain` with 3, `employee_submit_request` with 10) must be **gone**: `select count(*) from pg_proc where proname in (…)` gives 1 each.

   **Before** the apply, production must show these eight (read only, project `fgnbdlqmtezneznwvahf`, 2026-11-10):

| Function | `md5(prosrc)` on production | local, before phase 24 |
|---|---|---|
| `private.apply_decision` (5 args) | `73f8dc04b8280c2f44809abb8d192db3` | `9106be3a5416abb1f1019b5a239b2c8a` |
| `private.request_chain` (3 args) | `442977198625d11490b815325c7f0102` | same |
| `private.request_json(uuid)` | `3f2b567ff68bd04cf3e923a13a98c6a9` | `79999ef2e44e7a20b78de0ec866e6f5f` |
| `private.request_summary(uuid)` | `4e1b76209556af81d149e3e385894aeb` | same |
| `public.admin_get_approval_chains()` | `b73239299c404dddb98a1470368551ca` | same |
| `public.admin_set_approval_chain` (3 args) | `cbd04a6214ce2634b94b3e04f1bbc855` | same |
| `public.employee_requests_overview()` | `a0307a45a7b69810da130e9ed086138e` | same |
| `public.employee_submit_request` (10 args) | `d880979c2f3602bf443d2fdea1e9ef4b` | `5644aab84b44a799f338234948fe2ac6` |

   The three that differ differ **only in line endings**: production was applied from CRLF files, and the md5 of the local text with every LF turned into CRLF equals the production value exactly. Phase 24 replaces all three with LF text, which is harmless.
   **Catalog check on production (read only, 2026-11-10)**, because the migration drops and replaces some objects by name: `requests` has exactly **one** check constraint that mentions `annual` (`requests_leave_type_check`, the one the migration drops and recreates with `'custom'`; `requests_leave_type_required` stays valid); `approval_steps_order_uidx` has the definition the migration drops; `employees` has the unique key `(company_id, id)` the new foreign keys point at; `require_company_admin`, `audit_write`, `require_active_employee`, `private.leave_days`, `private.leave_balance`, `private.days_text` exist; no phase 24 table or column exists yet.
3. Check the grants and RLS (these are the values measured on the final local database): the nine `public.*` functions are executable by `authenticated` only (not `anon`, not `public`); the five `private.*` functions by nobody; the tables `custom_request_kinds` and `custom_kind_entitlements` have RLS on and no grant for `anon` / `authenticated` (not even `select`).
4. Install panel **12.23** (`waqti_admin_12_23.zip`, 95 files, `package.json` 12.23.0). A panel 12.23 on a database **without** the migration is safe: the pane «أنواع الطلبات» says «غير متاح بعد», the approvals screen and the employee form show no kind parts, and the chain saves send no new argument.
5. Build the app (`npm run build`). A new app on a database without the migration is safe too: the overview has no `custom_kinds`, so the form is exactly today's, and no request carries `p_custom_kind_id`.
6. Real-use test: (a) the admin adds a leave kind «حج» with 10 days → the employee sees «إجازات أخرى ← حج» with «المتبقي لك: 10 أيام»; he asks for 2 days → «حج: 2 أيام هذه السنة» under the balance, the request is titled «إجازة حج», the approvals follow the leave path; (b) a «طلب آخر» kind «سلفة» (one day) with its own approval path → the form shows one date; a kind «إفادة عمل» (no date) → no date field and no date line on the card; (c) days for one employee only → his balance changes, others keep the default; (d) a women-only kind is invisible to a man and refused (`kind_gender_mismatch`) if forced; (e) switching a kind off hides it in the app and keeps old requests with its name; a kind with requests cannot be deleted.

## 4. Rulings I made (to be confirmed by Omar)
P1–P5 were decided when the plan was written (spec amended in `1a5f02b`); the others during the build (the ledger has the full text of each).

| # | Ruling | Cost if wrong |
|---|---|---|
| P1 | `private.apply_decision` changes: at final approval a custom leave is re-checked against **its kind's** balance (`custom_leave_balance`), everything else as in phase 18a. The spec first said «unchanged». | A custom leave would be checked against a built-in balance. The rollback puts the phase 18a text back. |
| P2 | Phase 15/22/23 payloads keep `leave_type: 'custom'`; the label is «إجازة خاصة» where only the type is known, and the kind's name wherever `request_json` / `request_summary` are used. | One label per list. |
| P3 | Date mode `single`: `p_end_date` is ignored. `none`: both dates are ignored and the stored period is today (company time zone). `range`: as today's «طلب آخر». | One branch of `employee_submit_request`. |
| P4 | Per-employee days are edited on **existing** employees only; the create form shows «بعد إنشاء الحساب …». | The admin saves the employee first, then sets the days. |
| P5 | `admin_set_employee_kind_days` touches only the keys it is given; `null` deletes the override (back to the kind's default). | A caller expecting «missing key = reset» must send `null`. |
| R1 | A bad kind name raises the existing `invalid_name` (as `admin_save_permission_type` does), not `invalid_input`. | One code in the function and the tests. |
| R2 | A kind that needs a reason is enforced on a real submit only; a **dry run** (the balance preview) does not refuse it, like `insufficient_balance`. The app form blocks the send itself. | The form would learn the rule from the kind payload only. |
| R3 | The kind checks (exists, family, enabled) run **after** the duplicate-key return, so a retry of an already saved request answers even if the kind was switched off in between. | None. |
| R4 | A kind name that already starts with «إجازة» is not prefixed again («إجازة حج», never «إجازة إجازة حج»), in the panel, the app **and the notification text** (`private.request_summary`; the last one found by the final review). | One title string. |
| R5 | New optional arguments (`p_custom_kind_id`) are sent only when set, by the panel and the app, so a new client works against a database before phase 24 and the old exact-argument tests stay valid. | None (the new functions declare it `default null`). |
| R6 | The HR decision window keeps the «days taken» field for a custom leave and names the kind in its label (the database charges `coalesce(charged_days, days)` against the kind). | One label. |
| R7 | Excel: a custom «طلب آخر» keeps its reason in the reason column and the kind in the detail column; a no-date request shows «بدون تاريخ» in «من» and marks no day on the daily sheet. | A no-date request is absent from the daily sheet (it stays in «الطلبات»). |
| R8 | The date inputs of a one-day / period kind accept today−30 … today+365 (the server window); leave kinds keep the company's earliest-day rule. | A date the server refuses with `invalid_dates` (shown as the usual red line). |
| R9 | **Transition:** an **old app** (before this phase) that shows a custom leave request — a manager's inbox, say — has no label for `leave_type: 'custom'` and prints «إجازة undefined». Only requests made by a new app can be custom, so this lasts until the old app is replaced. | A cosmetic word in an old app for a short time; apply the app right after the panel. |

## 5. Rollback
`…_ROLLBACK.sql` puts back the earlier texts (phases 4d, 5, 18a, 18b) of the eight functions it replaced, drops the six new functions, the two tables, the two new columns (`requests.custom_kind_id`, `approval_steps.custom_kind_id`) with their constraints, restores the `leave_type` check without `'custom'`, and brings back the 10-argument `employee_submit_request` and the 3-argument `request_chain` and `admin_set_approval_chain`. Kind paths in `approval_steps` are deleted first (they would otherwise turn into plain «طلب آخر» steps). **It refuses to run while a custom request exists** (`rollback_refused_custom_requests_exist`) and leaves everything in place: after real use, removing the kinds would lose data, so that decision is Omar's.

**How the rollback was proven (2026-11-10):** `md5(prosrc)` of the eight functions on a database with phase 24 **plus** the rollback equals the one on a database without phase 24; no `custom_*` object is left; with one custom request present the rollback stops with the refusal and nothing changes. The whole suite then runs 1367 + 50 = 1417 passed, 0 failed (the 1417 of phase 23, with the pre-phase-24 `phase4` file).
