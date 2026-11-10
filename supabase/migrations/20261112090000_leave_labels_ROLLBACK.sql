-- Rollback of 20261112090000_leave_labels.sql: private.request_summary as phase 24 left it («طارئة», «أمومة»).

create or replace function private.request_summary(p_request uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case r.request_type
    when 'leave' then
      -- a kind named «إجازة حج» reads «إجازة حج», not «إجازة إجازة حج» (the panel and the app do the same)
      case when r.leave_type = 'custom' and k.name like 'إجازة%' then '' else 'إجازة ' end
      || case r.leave_type when 'annual' then 'سنوية' when 'sick' then 'مرضية' when 'emergency' then 'طارئة'
                                    when 'marriage' then 'زواج' when 'maternity' then 'أمومة' when 'unpaid' then 'بدون راتب'
                                    when 'custom' then coalesce(k.name, '') else '' end
      || ' · ' || private.days_text(r.days) || ' · '
      || to_char(r.start_at at time zone c.timezone, 'DD/MM')
      || case when (r.end_at - interval '1 second') at time zone c.timezone >= (r.start_at at time zone c.timezone)::date + 1
              then ' – ' || to_char((r.end_at - interval '1 second') at time zone c.timezone, 'DD/MM') else '' end
    when 'permission' then
      'إذن: ' || coalesce(pt.name, '') || ' · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM HH24:MI')
      || '–' || to_char(r.end_at at time zone c.timezone, 'HH24:MI')
    else
      coalesce(k.name, 'طلب آخر') || ' · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM')
  end
  from public.requests r
  join public.companies c on c.id = r.company_id
  left join public.permission_types pt on pt.id = r.permission_type_id
  left join public.custom_request_kinds k on k.id = r.custom_kind_id
  where r.id = p_request
$$;
revoke all on function private.request_summary(uuid) from public, anon, authenticated;
