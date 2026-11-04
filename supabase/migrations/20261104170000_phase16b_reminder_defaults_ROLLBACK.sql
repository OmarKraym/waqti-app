-- Rollback of phase 16b: the old defaults (reminders off, 10 minutes before) and no trigger.
-- The settings rows written by phase 16b stay as they are (each employee can change them in the app).
drop trigger if exists employees_default_notification_settings on public.employees;
drop function if exists private.default_notification_settings();

alter table public.notification_settings
  alter column remind_check_in set default false,
  alter column check_in_before set default 10,
  alter column remind_check_out set default false,
  alter column check_out_before set default 0;

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
    'remind_check_in', coalesce(s.remind_check_in, false),
    'check_in_before', coalesce(s.check_in_before, 10),
    'remind_check_out', coalesce(s.remind_check_out, false),
    'check_out_before', coalesce(s.check_out_before, 0),
    'devices', (select count(*) from public.push_subscriptions p where p.user_id = me.employee_id));
end;
$$;
revoke all on function public.employee_get_notification_settings() from public, anon;
grant execute on function public.employee_get_notification_settings() to authenticated;
