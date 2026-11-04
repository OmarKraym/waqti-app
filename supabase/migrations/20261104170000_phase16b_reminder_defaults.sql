-- Phase 16b: punch reminders are ON by default (decided by Omar, 2026-11-04):
--   check-in reminder 5 minutes before the shift, check-out reminder at the end of the shift, for EVERY employee.
--   * column defaults changed, so any new row (a new employee, a first device) starts "on"
--   * every existing employee is set to on / 5 / on / 0 (also those who had chosen something else: Omar's decision)
--   * a new employee gets the row at once (trigger), so nobody depends on opening the settings screen
--   * the employee can still turn the reminders off; saving a device never turns them back on
-- A reminder still needs a device with notifications allowed (push_subscriptions); the app now asks for that after sign-in.
-- Rollback: 20261104170000_phase16b_reminder_defaults_ROLLBACK.sql (puts back the old defaults; the rows set here stay).

do $guard$
begin
  if to_regclass('public.notification_settings') is null
     or to_regprocedure('public.employee_get_notification_settings()') is null
     or to_regprocedure('public.require_active_employee()') is null then
    raise exception 'phase16b: expected objects are missing (phase 5 must be applied first)';
  end if;
end
$guard$;

alter table public.notification_settings
  alter column remind_check_in set default true,
  alter column check_in_before set default 5,
  alter column remind_check_out set default true,
  alter column check_out_before set default 0;

insert into public.notification_settings (employee_id, company_id, remind_check_in, check_in_before, remind_check_out, check_out_before)
select e.id, e.company_id, true, 5, true, 0
from public.employees e
on conflict (employee_id) do update
  set remind_check_in = true, check_in_before = 5, remind_check_out = true, check_out_before = 0, updated_at = now();

-- ---------------------------------------------------------------- new employees
create or replace function private.default_notification_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notification_settings (employee_id, company_id) values (new.id, new.company_id)
  on conflict (employee_id) do nothing;
  return null;
end;
$$;
revoke all on function private.default_notification_settings() from public, anon, authenticated;

drop trigger if exists employees_default_notification_settings on public.employees;
create trigger employees_default_notification_settings
  after insert on public.employees
  for each row execute function private.default_notification_settings();

-- ---------------------------------------------------------------- the getter shows the same default when no row exists
create or replace function public.employee_get_notification_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  me record;
  s public.notification_settings;
begin
  select * into me from public.require_active_employee();
  select * into s from public.notification_settings where employee_id = me.employee_id;
  return jsonb_build_object(
    'remind_check_in', coalesce(s.remind_check_in, true),
    'check_in_before', coalesce(s.check_in_before, 5),
    'remind_check_out', coalesce(s.remind_check_out, true),
    'check_out_before', coalesce(s.check_out_before, 0),
    'devices', (select count(*) from public.push_subscriptions p where p.user_id = me.employee_id));
end;
$$;
revoke all on function public.employee_get_notification_settings() from public, anon;
grant execute on function public.employee_get_notification_settings() to authenticated;
