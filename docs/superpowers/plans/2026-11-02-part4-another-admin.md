# Part 4 — Another system admin (phase16) Implementation Plan

> Inline execution (TDD). Spec: `docs/superpowers/specs/2026-11-02-onboarding-review-admins-handling-design.md` § Part 4.

**Goal:** a company admin can see the admins of the company, promote an existing active employee to admin, and take the admin role away again — without ever leaving the company with no working admin.

**Architecture:** admin = `company_members.role = 'company_admin'` of an **active** employee of an **active** company (that is exactly what `public.admin_company_id()` checks). The role lives only in the database (the `company_role` claim in `auth.users.raw_app_meta_data` is a creation-time hint and nothing reads it afterwards), so promotion and removal take effect on the next call, with no new sign-in. Three RPCs behind `require_company_admin()`; one small private helper for the "other working admins" count; no table change, no service_role.

**Tech:** Postgres 16 local suite (`supabase/local/test-db.sh`), admin panel (plain ES modules, outside the repo).

## Decisions (rulings)

- R1. `admin_remove_admin` sets the role back to `employee`; the membership row is kept (the person stays an employee).
- R2. "Last admin" means last **working** admin: only active employees count (an inactive admin cannot sign in to the panel). Counting excludes the person being removed.
- R3. Self-removal is refused (`cannot_remove_self`). Because the caller is always a working admin, the "last admin" count can only fail if two admins remove each other **at the same time**; so the three steps run under a per-company advisory lock, and the caller is re-checked after the lock is taken (`forbidden`). This is verified with a real two-session script, not only by the unit tests.
- R4. An inactive admin (stale row) can be removed by another admin (cleanup), and is listed with `is_active = false`.
- R5. `since` = time of the latest `admin.added` audit row for that person, else the membership creation time.
- R6. A promoted person with a temporary password is not blocked here: `require_company_admin()` already stops every admin call until the password is changed. The panel pane shows a hint.
- R7. Fingerprint login is already refused for admins (`password_required`, phase 9/10); a promoted employee who had a registered device simply signs in with the password. Told to Omar; not changed.
- R8. `reset-employee-password` already refuses to reset an admin (`cannot_reset_manager`). Kept: a promoted admin's password can only be changed by themselves.
- R10. **Side effect, existing rule:** `private.can_decide` and the "approval needed" notice treat every active company admin as the `hr` approver. So a new admin can decide `hr` steps and is notified of them at once; a removed admin loses both. Not changed (the spec calls the admin the system admin and `hr` steps are the admin's); pinned by two tests and written in the pane text and README so Omar is not surprised.
- R9. No notice to the promoted/removed person (admin notices stay inside the panel; spec says nothing more).

## Contracts

```
public.admin_list_admins() -> table(id uuid, full_name text, employee_number text, email text,
                                    is_active boolean, is_me boolean, since timestamptz)   -- order by since, full_name
public.admin_add_admin(p_employee_id uuid)    -> jsonb {employee_id, full_name, employee_number}
   errors: not_found (no such employee in my company, also another company's / null), already_admin, employee_inactive
public.admin_remove_admin(p_employee_id uuid) -> jsonb {employee_id, full_name, employee_number}
   errors: not_found, cannot_remove_self, not_admin, forbidden (caller lost the role while waiting), last_admin
private.working_admin_count(p_company uuid, p_except uuid) -> integer
audit: admin.added / admin.removed  (target_type 'employee', target_id = employee id, details {employee_number, full_name})
grants: authenticated only (revoke from public, anon); private helper revoked from everyone
```

## Tasks

1. **DB tests first** — `supabase/tests/phase16_admins_tests.sql`; run, see them fail for the right reason (functions missing).
2. **Migration** — `20261102190000_phase16_admins.sql` (+ `_ROLLBACK.sql`, guard block). Run the new file green, then the full suite.
3. **Mutation + concurrency checks** — break the migration five ways (each must turn a test red); two-session script for R3, including the run without the lock (must end with zero admins, proving the script can fail).
4. **Panel 12.7** — «مديرو النظام» pane (list, add from picker of active non-admin employees, remove with confirm), errors, fake client, behavior + layout tests, README, zip.
5. **Final check** — whole DB suite, panel suites, rollback check, self-review; report to Omar and wait for an explicit «نعم» before touching production.

## Review focus (inputs the tests must hit)

- Another company's employee → `not_found` for both add and remove; admin of company B cannot see company A's admins.
- Inactive employee cannot be promoted; inactive admin does not count as a working admin.
- Non-admin, anon, and an admin with a temporary password are refused.
- Removing the admin role never removes the person (employee row, membership row, requests stay).
- Promoted admin can open admin RPCs immediately (e.g. `admin_list_employees`); removed admin cannot, immediately.
