-- ROLLBACK for 20261031140000_phase6_overtime.sql
-- DATA LOSS: all overtime assignments and the overtime limits are deleted.
drop function if exists public.admin_list_overtime(date, uuid);
drop function if exists public.admin_set_overtime_settings(integer, integer);
drop function if exists public.admin_get_overtime_settings();
drop function if exists public.employee_overtime_note(uuid, text);
drop function if exists public.manager_cancel_overtime(uuid);
drop function if exists public.manager_assign_overtime(uuid, uuid, timestamptz, timestamptz, text, boolean);
drop function if exists public.employee_overtime_overview();
drop function if exists private.overtime_when(uuid);
drop function if exists private.overtime_json(uuid);
drop function if exists private.overtime_used(uuid, date, text, uuid);
drop function if exists private.overtime_actual(uuid, timestamptz, timestamptz);
drop function if exists private.manages(uuid, uuid);
drop table if exists public.overtime_assignments;
delete from public.notifications where kind in ('overtime_assigned', 'overtime_cancelled', 'overtime_note');
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('approval_needed', 'request_decided', 'reminder_check_in', 'reminder_check_out', 'test'));
alter table public.companies drop column if exists overtime_max_day_minutes, drop column if exists overtime_max_month_minutes;
