-- Rollback of phase 19c: no late status for the employee, no table-level guard on the monthly limit.
-- (employee_submit_request keeps its own check of the limit; nothing else used these.)
drop trigger if exists requests_limit_guard on public.requests;
drop function if exists private.requests_limit_guard();
drop function if exists public.employee_late_status(uuid);
