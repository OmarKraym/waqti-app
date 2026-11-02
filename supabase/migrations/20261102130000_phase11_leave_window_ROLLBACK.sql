-- Rollback of 20261102130000_phase11_leave_window.sql: leave may start up to 30 days back again (the old fixed rule in
-- employee_submit_request). Audit rows already written stay.
drop trigger if exists requests_leave_window on public.requests;
drop function if exists private.enforce_leave_window();
drop function if exists public.employee_leave_window();
drop function if exists public.admin_set_leave_window(integer, integer);
drop function if exists public.admin_get_leave_window();
drop function if exists private.leave_earliest(uuid, date);
alter table public.companies drop constraint if exists companies_leave_window_one_way;
alter table public.companies drop column if exists leave_back_days, drop column if exists leave_notice_days;
