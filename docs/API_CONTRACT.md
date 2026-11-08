# Waqti PWA — Server API Contract

Status: **live in production** (2026-10-29). Implemented in `waqti-db/phase2/` (67 passing tests) and
re-verified on production with real data inside a rolled-back transaction (shapes, out-of-range refusal,
retry without duplicate, stale-screen refusal).

Both RPCs are `SECURITY DEFINER` Postgres functions called with the employee's own JWT.
The server finds the employee and the company from `auth.uid()` only. The client never sends
`employee_id` or `company_id`.

---

## 1. `employee_attendance_state()` → `jsonb`

No arguments. Returns the state that drives the home screen.

```json
{
  "employee": { "full_name": "أحمد سالم", "employee_number": "1024" },
  "company":  { "name": "شركة ...", "timezone": "Africa/Tripoli" },
  "next_action": "check_in",
  "open_session": null,
  "location_policy": "geofence",
  "outside_action": "flag",
  "max_accuracy_m": 100,
  "recent_events": [
    { "id": "uuid", "action": "check_in", "server_time": "2026-10-29T07:05:00Z",
      "location_status": "inside", "needs_review": false, "by_admin": false }
  ],
  "server_time": "2026-10-29T07:10:12Z"
}
```

| Field | Rule |
|---|---|
| `next_action` | `check_out` if the employee has an open session, else `check_in`. The **only** source of the button label. |
| `open_session` | `{ "started_at": iso }` or `null`. |
| `location_policy` | `geofence` \| `record` \| `none` (per employee; company default when not set). |
| `outside_action` | `flag` \| `reject`. Used only with `geofence`. |
| `max_accuracy_m` | Readings with worse accuracy are `inaccurate`. Company setting. |
| `recent_events` | Newest first, max 10, own events only. `by_admin` (phase 20b) is `true` when the admin added the movement (`authentication_method = 'admin'`: a forgotten punch added with `admin_add_punch`, or a correction of the review queue). An older server sends no `by_admin`; the app reads a missing key as `false`. |
| `server_time` | `now()`. The PWA shows its clock from this, not from the phone. |

Errors: `not_authenticated`, `employee_inactive`, `must_change_password`.

---

## 2. `employee_punch(...)` → `jsonb`

| Argument | Type | Notes |
|---|---|---|
| `p_request_id` | `uuid` | Idempotency key, new for every tap, reused on retry. |
| `p_expected_action` | `text` | The action the employee saw on the button. |
| `p_reading` | `text` | `ok` \| `denied` \| `unavailable` \| `timeout` \| `unsupported` \| `not_requested` |
| `p_lat`, `p_lng` | `double precision` | Only when `p_reading = 'ok'`. |
| `p_accuracy_m` | `double precision` | Only when `p_reading = 'ok'`. |

Returns:

```json
{ "event_id": "uuid", "action": "check_in", "server_time": "2026-10-29T07:05:00Z",
  "location_status": "inside", "needs_review": false, "duplicate": false }
```

### Server rules (in this order)

1. **Idempotency.** If `(employee_id, p_request_id)` already exists, return that event with
   `duplicate: true`. Nothing new is written. Enforced by a unique index, not only by a check.
2. **Account checks.** Active employee, active company, no forced password change.
3. **State check.** Lock the employee's row (`FOR UPDATE`) and compute the real next action.
   If it differs from `p_expected_action`, raise `state_changed` (e.g. punched on another phone).
4. **Location status** (server decides; the client only reports):

| Policy | Reading | `location_status` |
|---|---|---|
| `none` | anything | `not_requested` (coordinates ignored, not stored) |
| `record` | ok, accuracy ≤ max | `recorded` |
| `record` | ok, accuracy > max | `inaccurate` |
| `record` | no reading | `unavailable` |
| `geofence` | ok, accuracy ≤ max, inside | `inside` |
| `geofence` | ok, accuracy ≤ max, outside | `outside` |
| `geofence` | ok, accuracy > max | `inaccurate` |
| `geofence` | no reading | `unavailable` |

5. **Decision for `geofence`** when the status is not `inside`:

| `outside_action` | `outside` | `inaccurate` | `unavailable` |
|---|---|---|---|
| `reject` | raise `outside_geofence` | raise `location_inaccurate` | raise `location_required` |
| `flag` | save, `needs_review = true` | save, `needs_review = true` | save, `needs_review = true` |

   `record` and `none` never reject because of location.

6. **Write** the event with `server_time = now()` (never a client time), `company_id` from the
   employee row, and `work_date` computed in the **company time zone**.
7. **Rate limit:** more than 5 punches in 60 seconds → `rate_limited`.

### Error codes

Raised as the exception message (`raise exception 'outside_geofence'`), SQLSTATE `P0001`.
The PWA maps them in `src/lib/errors.ts`:

`not_authenticated`, `employee_inactive`, `must_change_password`, `forbidden`, `state_changed`,
`outside_geofence`, `location_required`, `location_inaccurate`, `rate_limited`,
`geofence_not_configured` (geofence policy but no active area), `invalid_input`.

A response with **no** SQLSTATE (lost connection, timeout) is treated as `network`: the PWA does
**not** know whether the punch was saved, says so, and offers a retry with the same `p_request_id`.

---

## Existing pieces reused as-is

| Piece | Used for |
|---|---|
| Supabase Auth (email + password) | Login, persistent session |
| Edge Function `change-password` | First-login forced password change (`app_metadata.must_change_password`) |


---

## 3. Offline punches (Phase 3, live 2026-10-30)

Decided by Omar: accepted **only if the phone clock is consistent** (no admin review), refused if it
reaches the server **more than 72 h** after the punch, same location rules as online.

### Signed time token

`employee_attendance_state()`, `employee_punch()` and `employee_punch_offline()` now also return
`time_token` (`v1.<server ms>.<HMAC-SHA256>`, key in `private.app_secrets`, never exposed).
The phone keeps the latest token as its anchor, with the phone clock (and `performance.now()`) when it arrived.

### `employee_punch_offline(...)` → same result as `employee_punch` (+ `time_token`)

| Argument | Notes |
|---|---|
| `p_request_id`, `p_expected_action`, `p_reading`, `p_lat`, `p_lng`, `p_accuracy_m` | As online. |
| `p_time_token` | Latest token received before the tap. |
| `p_token_device_time` | Phone clock when that token arrived. |
| `p_device_time` | Phone clock at the tap. |
| `p_monotonic_ms` | ms since the token on the monotonic clock; `null` if the app was restarted. |
| `p_device_now` | Phone clock when sending. |

Server checks, in order (any failure = refused, nothing written):

1. Same `p_request_id` already saved → returns it with `duplicate: true` (no other check).
2. Token valid for this employee, else `time_unverified`.
3. Phone offset at token time = phone offset now (±120 s), else `clock_changed`.
4. Claimed time = `p_device_time` + offset. With a monotonic value: the claimed time may not be
   more than 120 s **earlier** than `token time + monotonic` (one-sided: phones may pause that clock
   while asleep), else `clock_changed`.
5. Token time − 5 s ≤ claimed ≤ now + 5 s, else `clock_changed`; claimed ≥ now − 72 h, else `offline_too_old`.
6. Then exactly the online rules at the claimed time: `time_order` (must be after the last event),
   `rate_limited`, `state_changed`, location policy (`outside_geofence` / `location_required` / …).

The event keeps `occurred_at` = claimed time and `created_at` = receive time; `metadata.source = 'pwa_offline'`.

**Residual risk (cannot be closed on the web):** someone who hand-crafts API requests can still pick a
time between their last server contact and the sync (≤ 72 h). Normal phone-clock changes are caught.

---

## 5. `employee_late_status(p_event_id uuid)` → `jsonb` (phase 19c)

Asked by the app right after an **online check-in** was saved (not for a duplicate, a check-out, or a punch that was saved on the
phone and sent later). The server decides everything: whether the arrival is late, the grace period, the company's counting
rule, whether the employee can still request a late-arrival justification. The app shows a dialog only for `offer`.
`stable`, `security definer`, granted to `authenticated` only. Without the function (database older than the app) the app
gets "function not found" and shows nothing (`Api.getLateStatus` returns `null`; it also returns `null` when offline).

Errors: `not_authenticated`/`employee_inactive` as everywhere; `event_not_found` (22023) when the event is not the caller's.

```jsonc
{
  "event_id": "…",
  "late_min": 40,            // minutes after the shift start, rounded UP (08:15:30 against 08:00 = 16); 0 = on time / early
  "grace_min": 15,           // the employee's grace period (his own, else the company's)
  "chargeable_min": 40,      // minutes that count: rule all_after_grace = all of late_min once it is above the grace, else 0;
                             // rule beyond_grace = late_min − grace_min (never below 0)
  "deduction_min": null,     // minutes of pay by the dated deduction policy; null = no policy covers the day, or not a first arrival
  "rule": "all_after_grace", // or "beyond_grace"
  "remaining": 3,            // justifications left this month for the late-arrival type (null = no monthly limit, or type not reached)
  "offer": true,             // = (reason = 'offer')
  "reason": "offer",
  "permission": { "id": "…", "name": "…", "mode": "late_arrival", "max_per_month": 3, "max_minutes": 60,
                  "days_back": 0, "days_ahead": 0, "month": "2026-11", "used": 0, "pending": 0 }   // null when the type was not reached
}
```

`reason`, in the order the server decides: `not_check_in` → `day_off` (no shift that day) → `not_first` (an earlier check-in the
same day) → `not_late` (late_min = 0) → `within_grace` (chargeable_min = 0) → `no_type` (no active late-arrival type) →
`already` (a pending/approved late-arrival request for that day) → `no_balance` (remaining = 0) → `too_long`
(late_min > the type's max_minutes) → `outside_window` (the day is outside the type's days_back/days_ahead) → `offer`.

**The app treats every reason other than `offer` as "no offer"** (also one added later). For `no_balance`, `too_long` and
`already` it shows one dismissible line above the punch button saying why (`lateNote`); for the others nothing.

The monthly limit is also enforced at the table: a `before insert` trigger on `public.requests` (pending permission requests)
takes a per-employee advisory lock and refuses with `permission_limit` when the month's allowance is used up, so two
simultaneous requests cannot both pass.

---

## 6. Company late rule (phase 19a) — administration

`companies.late_rule` = `all_after_grace` (default; the phase 12 behaviour: inside the grace nothing counts, beyond it ALL minutes since the shift
start count) or `beyond_grace` (inside the grace nothing counts, beyond it only the minutes after the grace). One rule for late arrival and early
leave. `private.punch_lateness(employee, event, type, at)` keeps its signature and reads the rule through `private.chargeable_minutes(raw, grace, rule)`.

| Function | Notes |
|---|---|
| `admin_get_grace_settings()` → `{late_grace_min, early_grace_min, late_rule}` | `late_rule` is new. A panel older than the database ignores it; a panel newer than the database gets no `late_rule` and hides the choice. |
| `admin_set_late_rule(p_rule text)` → same object | `invalid_settings` (22023) for anything but the two values. Audited as `company.late_rule`. Lateness is computed when read, so the change also changes how old days read. |

## 7. Late deduction policies (phase 19b) — administration

Table `public.deduction_policies` (RLS on, no direct access): per company, dated (`effective_from`), `kind` = `proportional` or `tiers`.
**The deduction is in minutes of pay**, never money. Policy of a day = the one with the greatest `effective_from` on or before it; before the first one: nothing.
`editable` = `effective_from >= the company's today`; an older policy is history (`policy_locked`).

```jsonc
{ "kind": "proportional", "params": { "per_minutes": 15, "deduct_minutes": 10, "round_to": 5, "rounding": "up" } }
// per_minutes 1–240, deduct_minutes 0–1440, round_to ∈ {1,5,10,15,30,60}, rounding ∈ up | down | nearest
{ "kind": "tiers", "params": { "tiers": [ { "from": 1, "to": 15, "deduct": 0 }, { "from": 16, "to": 30, "deduct": 30 }, { "from": 31, "to": null, "deduct": 60 } ] } }
// 1–50 tiers, from ≥ 1, deduct 0–1440, no gap and no overlap, only the last tier may be open (to = null)
```

| Function | Returns / errors |
|---|---|
| `admin_list_deduction_policies()` | `[{id, effective_from, kind, params, editable, created_at}]`, newest first |
| `admin_save_deduction_policy(p_id uuid, p_effective_from date, p_kind text, p_params jsonb)` | the saved policy (same shape). `p_id` null = new. `invalid_settings`, `policy_locked` (start date in the past, or the policy already started), `policy_date_taken`, `policy_not_found`. Audited. |
| `admin_delete_deduction_policy(p_id uuid)` | `policy_locked`, `policy_not_found`. Audited. |
| `admin_preview_deduction(p_policy jsonb, p_late_after_start integer[])` | `[{late, chargeable, deduct}]` using the company's grace and rule; 1–50 values of 0–1440. The panel shows these numbers and never recomputes them. |
| `admin_list_attendance(...)` | two columns added at the END: `deduction_minutes integer`, `deduction_state text` — for the employee's FIRST check-in of a local day only (otherwise null): `none` / `excused` (an approved late-arrival justification covers the arrival minute) / `pending` (a covering one still waits; minutes provisional) / `due`. |

## 8. The admin adds a forgotten check-in or check-out (phase 20) — administration

`admin_add_punch(p_employee_id uuid, p_type text, p_time timestamptz, p_reason text)` → `{event_id, event_type, session_id, session_status}`
(`security definer`; the caller must be a company admin; the employee must belong to the caller's company).

The movement is saved like a normal punch, so lateness, early leave and the phase 19 deduction are counted **by the time the admin writes**
(decision «أ» of 2026-11-08): `authentication_method 'admin'`, `location_status 'not_requested'`, `location_policy 'none'`,
`metadata {source: 'admin_manual', reason, added_by}`. Audited as `attendance.manual_add`.

| Rule | Detail |
|---|---|
| Reason | required, 3–500 characters after trimming (`reason_required`, 22023) |
| Time | in the past and at most 62 days back; not the exact time of another event of that employee (`invalid_time`) |
| Employee | does not have to be active (payroll may need a former employee's last days) |
| `check_in` | refused with `open_session` when he has an open session; with `overlaps_session` inside a closed session of his; with `unpaired_checkout` right before a check-out that has no check-in on the same day (that one belongs to the review queue: `admin_resolve_review`). The session is `open` when the time is today and nothing comes after it; otherwise `missed_checkout`, and the check-in is flagged `needs_review` with `metadata.missed_checkout = true`, like a forgotten check-out found by the system. |
| `check_out` | closes the latest `open` / `missed_checkout` session whose check-in is before the time (`no_open_session` when there is none). `invalid_time` when more than 24 h passed since that check-in, or when another event of his lies between them. The check-in's `missed_checkout` flag is cleared, and its `needs_review` too unless something else needs a look (a `suspect` entry, or a location that was not `inside` / `recorded` / `not_requested`). |

Errors: `invalid_action`, `reason_required` (22023); `invalid_time`, `not_found`, `open_session`, `overlaps_session`, `unpaired_checkout`, `no_open_session` (P0001); `forbidden` (42501) for a non-admin.
Nothing existing is changed or deleted. Rollback: drop the function (the events it created stay as history).

`admin_list_attendance` already returns `authentication_method`; the panel prints «أضافه المدير» for `admin`. Phase 20b adds `by_admin` to the employee's `recent_events` (§1).

### 8b. The admin adds the forgotten check-out from the review window (phase 20c)

`admin_resolve_review(p_event_id uuid, p_action text, p_time timestamptz default null, p_note text default null)` accepts a third action, `'add_check_out'`
(the mirror of `'add_check_in'`); `'accept'` and `'add_check_in'` behave as before. The result gains one key, `check_out_event_id` (null for the other two actions).

| Rule | Detail |
|---|---|
| Which event | a check-in flagged «missed check-out» whose session waits (`missed_checkout`); anything else is `invalid_action`. An already resolved check-in is `already_resolved`. |
| Time | after the check-in, at most **24 h** after it, not in the future, with no other event of the employee in between (`invalid_time`) |
| What is saved | a check-out as a **correction** of the flagged check-in (`authentication_method 'admin'`, `metadata {source 'admin_correction', corrects_event, review}`); that very session is closed; the check-in leaves the review queue with `missed_checkout` false |
| Audit | `attendance.review_add_check_out` |

Nothing is deleted. Rollback: `20261108150000_phase20c_review_add_check_out_ROLLBACK.sql` puts the phase 14 function back (fingerprint `9689e17d…`).

## 9. Delete a work place, delete an employee (phase 21) — administration

"Delete" hides: nothing is erased. `work_locations.deleted_at` and `employees.deleted_at` (null = live); a deleted employee is also inactive (check constraint).
Both functions are `security definer`, for a company admin only (`forbidden` 42501 otherwise), `anon` cannot execute them.

### `admin_delete_work_location(p_location_id uuid, p_move_to uuid default null)` → `{deleted: true, moved: n}`

| Case | Result |
|---|---|
| The place has **active** employees and no `p_move_to` | `has_employees` |
| `p_move_to` is the place itself, deleted, in another company, or unknown | `invalid_target` |
| Unknown place / other company / already deleted | `not_found` |
| Active employees | moved to `p_move_to` and given its geofence (the same copy `admin_save_employee_profile` makes); an employee with his own geofence keeps it |
| Inactive employees | stay on the old place (history); to activate one later the admin picks a live place for him |

Audited as `work_location.delete` (name, how many were moved, where to). Both place rows are locked (in id order) first, so a move into a place being deleted at the same moment is seen. The place name can be added again afterwards
(the unique name index covers live places only). A trigger keeps people off a deleted place: nobody is moved into it, and nobody whose place was deleted
becomes active before he gets a live place.

### `admin_delete_employee(p_employee_id uuid, p_confirm_name text)` → `{deleted: true}`

Refusals, checked in this order (all `P0001`, message = code): `not_found`, `self_delete`, `is_admin`, `name_mismatch`, `open_session`, `pending_requests`, `has_reports`
(he is the direct manager of others), `is_approver` (he is a named approver in a step of an approval chain).
The typed name must equal his name after trimming, collapsing runs of spaces (the non-breaking one too) and Unicode normalisation (NFC).

On success: `deleted_at` and `is_active = false`; his phone binding is removed (`admin_remove_device`) and his push subscriptions are deleted; audited as `employee.delete`.
His attendance, requests and audit rows are not touched. **His employee number and e-mail stay reserved** (the unique constraints and the auth user remain).

### Changed lists

- `admin_list_work_locations`: hides deleted places; `employees_count` counts people who are not deleted; **new key `active_count`** (how many of them are active).
- `admin_list_employees`: hides deleted employees; same columns.
- `platform_list_companies`: counts people who are not deleted.
- `admin_add_work_location`: re-created only because the conflict target of the name index now needs its `WHERE`.

Rollback: `20261109100000_phase21_workplaces_delete_employee_ROLLBACK.sql` restores the four functions exactly, drops the two delete functions and the trigger, and brings the old unique name index back. It **keeps** the two `deleted_at` columns and the check constraint (the record of what was deleted); a place deleted earlier gets a suffix «(محذوف <date> <id>)» in its name, so after a rollback it shows in the lists again, marked as deleted; a deleted employee stays inactive.
