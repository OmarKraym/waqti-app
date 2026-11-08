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
      "location_status": "inside", "needs_review": false }
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
| `recent_events` | Newest first, max 10, own events only. |
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
