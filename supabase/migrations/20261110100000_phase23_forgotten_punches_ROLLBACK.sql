-- Rollback of phase 23. The queue goes back to its phase 15 text (read-only, "stable"); the three functions and the table of decisions
-- are dropped (the "absent" decisions are lost with the table). Sessions already closed as "missed check-out" stay so: that is data.
create or replace function public.admin_review_queue(p_limit integer default 200)
returns table(event_id uuid, employee_id uuid, employee_number text, full_name text, event_type public.attendance_event_type,
  occurred_at timestamp with time zone, location_status text, suspect text[], biometric text, missed_checkout boolean,
  offline boolean, sync_delay_s integer, needs_review boolean, review_total bigint, leave jsonb)
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return query
  select ev.id, ev.employee_id, emp.employee_number, emp.full_name, ev.event_type, ev.occurred_at, ev.location_status,
         coalesce(array(select jsonb_array_elements_text(ev.metadata -> 'suspect')), '{}'::text[]),
         ev.metadata ->> 'biometric',
         coalesce((ev.metadata ->> 'missed_checkout')::boolean, false),
         coalesce((ev.metadata ->> 'offline')::boolean, false),
         (ev.metadata ->> 'sync_delay_s')::integer,
         ev.needs_review,
         count(*) over (),
         case when ev.metadata ? 'leave_request_id' then
           (select jsonb_build_object('request_id', r.id, 'leave_type', r.leave_type, 'status', r.status, 'days', r.days,
                                      'start_date', (r.start_at at time zone c.timezone)::date,
                                      'end_date', ((r.end_at - interval '1 second') at time zone c.timezone)::date,
                                      -- the days of the leave the admin can cancel (his working days inside the range)
                                      'working_days', coalesce((
                                        select jsonb_agg(g::date order by g)
                                        from generate_series((r.start_at at time zone c.timezone)::date,
                                                             ((r.end_at - interval '1 second') at time zone c.timezone)::date, interval '1 day') as g
                                        where r.status = 'approved' and private.leave_days(r.employee_id, g::date, g::date) > 0), '[]'::jsonb))
            from public.requests r join public.companies c on c.id = r.company_id
            where r.id = (ev.metadata ->> 'leave_request_id')::uuid and r.company_id = v_company)
         end
  from public.attendance_events ev
  join public.employees emp on emp.id = ev.employee_id
  where ev.company_id = v_company and ev.needs_review
  order by ev.occurred_at desc, ev.id
  limit greatest(least(coalesce(p_limit, 200), 1000), 1);
end;
$$;
revoke all on function public.admin_review_queue(integer) from public, anon;
grant execute on function public.admin_review_queue(integer) to authenticated;
drop function public.admin_dismiss_missing_checkin(uuid, date, text);
drop function public.admin_list_missing_checkins(integer);
drop function private.missing_checkins(uuid, uuid);
drop function private.close_forgotten_sessions(uuid);
drop table public.attendance_day_decisions;
