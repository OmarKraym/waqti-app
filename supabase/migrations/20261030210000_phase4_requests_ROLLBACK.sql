-- ROLLBACK for 20261030210000_phase4_requests.sql (requests + approval chain).
-- Run ONLY if phase 4 must be removed. It deletes every approval step and approval record,
-- and the leave/permission details stored on requests (type, days, minutes, keys).
-- Requests themselves stay (status, dates, reason, decision).
-- Tested locally: after this file the schema fingerprint is identical to before phase 4.

do $guard$
begin
  if to_regclass('public.approval_steps') is null then
    raise exception 'phase 4 is not applied';
  end if;
end
$guard$;

drop function if exists public.employee_requests_overview();
drop function if exists public.employee_submit_request(uuid, text, text, date, date, timestamptz, timestamptz, text, boolean);
drop function if exists public.employee_cancel_request(uuid);
drop function if exists public.approver_inbox();
drop function if exists public.approver_decide(uuid, text, text);
drop function if exists public.admin_set_employee_manager(uuid, uuid);
drop function if exists public.admin_get_approval_chains();
drop function if exists public.admin_set_approval_chain(text, jsonb);
drop function if exists public.admin_set_request_settings(integer);
drop function if exists public.admin_list_requests(text, text, uuid, integer, integer);
drop function if exists public.admin_decide_request(uuid, text, text);

drop function if exists private.apply_decision(uuid, text, text, uuid, boolean);
drop function if exists private.can_decide(public.request_approvals, uuid);
drop function if exists private.request_json(uuid);
drop function if exists private.request_chain(uuid, public.request_type);
drop function if exists private.permission_used(uuid, date, uuid);
drop function if exists private.leave_balance(uuid, text, int, uuid);
drop function if exists private.leave_days(uuid, date, date);

drop table if exists public.request_approvals;
drop table if exists public.approval_steps;

drop index if exists public.requests_employee_period_idx;
drop index if exists public.requests_key_uidx;
alter table public.requests
  drop constraint if exists requests_leave_type_required,
  drop constraint if exists requests_reason_length,
  drop column if exists leave_type,
  drop column if exists days,
  drop column if exists minutes,
  drop column if exists request_key,
  drop column if exists current_step;

-- before phase 4: the policy existed, and "authenticated" had SELECT only on requests (no INSERT grant).
create policy requests_insert_self on public.requests
  as permissive for insert to authenticated
  with check ((employee_id = auth.uid()) and (status = 'pending'::public.request_status));

alter table public.companies drop column if exists permission_minutes_per_month;

drop index if exists public.employees_manager_idx;
alter table public.employees
  drop constraint if exists employees_manager_same_company,
  drop constraint if exists employees_manager_not_self,
  drop column if exists manager_id;
