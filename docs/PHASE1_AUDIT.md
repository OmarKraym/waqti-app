# Phase 1 — Existing System Audit (2026-10-29)

Scope: live Supabase project `waqti` (eu-west-1, read-only queries), its 3 Edge Functions, and the
admin panel zip received today. The memorandum and the Flutter source were **not** available.

## 1. Database (live)

| Table | Rows (approx.) | RLS | Policies | `company_id` |
|---|---|---|---|---|
| employees | 67 | on | read self | no |
| employee_geofences | 63 | on | read self | no |
| employee_work_schedules | 455 | on | none (functions only) | no |
| employee_compensation | 65 | on | none | no |
| employee_salary_components | – | on | none | no |
| employee_leave_entitlements | – | on | none | no |
| leave_policy | – | on | none | no |
| work_locations | – | on | none | no |
| attendance_events | **2** | on | read self | no |
| attendance_sessions | 0 | on | read self | no |
| requests | – | on | insert/read self | no |

- No table has `company_id`. Multi-tenancy is a full schema change (Phase 2).
- Attendance is almost unused (2 events). **Changing the attendance logic now carries little data risk.**
- 21 public functions. All `admin_*` are `SECURITY DEFINER` and check a **global** manager role.

## 2. Findings, by severity

### 🔴 Critical — client-controlled attendance time
`record_attendance(..., p_occurred_at timestamptz default now())` stores **the time the caller sends**.
Any employee can call the RPC directly and record a check-in at any past time (for example 08:00 when
they arrived at 10:00). The geofence validity window also uses this time. This breaks the
"server-authoritative timestamp" rule.
*Likely reason:* it was added for the Flutter offline sync (drift), which sends stored times.
**Fix:** ignore client time; use `now()`. Offline sync is not approved, so nothing approved depends on it.
Needs Omar's approval because it may break the current Flutter build.

### 🟠 High
- **Global manager role** in every `admin_*` function and in `create-employee` /
  `reset-employee-password` (`app_metadata.role = 'manager'`). Not tenant-aware.
- **`reset-employee-password`** loads any user with the service role; after multi-tenancy a manager
  could reset another company's employee. Needs a same-company check.
- **Duplicate request = error.** A retry with the same `request_id` raises
  `duplicate_attendance_request` instead of returning the saved event, so a retry after a lost
  reply looks like a failure although the punch was saved.

### 🟡 Medium
- `work_date` is computed in **UTC**, not Libya time (a check-in at 00:30 local goes to the previous day).
- Location is always required: `p_latitude/p_longitude` are used even when `geofence_required = false`;
  there is no "record only", "no location" or "flag for review" mode.
- `anon` can EXECUTE `record_attendance` and `handle_new_auth_user` (Supabase advisor). The first
  rejects anonymous callers inside, but EXECUTE should be revoked anyway.
- Employee code uniqueness is global, not per company.
- Audit trail exists only as `console.log` in an Edge Function (no audit table).

### 🔵 Low
- Supabase Auth: leaked-password protection is disabled.
- `set_updated_at` has a mutable `search_path`.
- `change-password` signs in once to compare passwords, which creates one extra unused session.

## 3. Admin panel zip

The received `waqti_admin.zip` is the **first version** (16 Oct): employee list, add/edit, per-employee
geofence. It does not contain features that exist in the database and were built later: attendance log
+ Excel export, full HR profile, Excel import, password reset button, work-location geofences.
The admin panel will not be changed until the current version is confirmed.

## 4. Gap summary

| Requirement | Current | Gap |
|---|---|---|
| Multi-company + RLS isolation | single company | Phase 2 (schema, helpers, policies, functions) |
| Platform / Company admin | one global `manager` | Phase 2 |
| Server time only | client time accepted | Critical fix |
| 3 location policies + flag/reject | geofence on/off, reject only | new `employee_punch` |
| Safe retry | duplicate → error | new `employee_punch` |
| Employee PWA | Flutter | **built** (`waqti-pwa`), waiting for the RPCs |
| Audit log | logs only | Phase 2 |
| QR removed | not found in DB | nothing to remove server-side |
