-- Rollback of phase 20c: the phase 14 version of admin_resolve_review() (actions accept and add_check_in only; no check_out_event_id key).
-- A check-out already added by the admin stays as history (a normal event with source 'admin_correction').
-- accept: the punch stays as recorded, the flag is cleared.
-- add_check_in: only for a check-out flagged missing_checkin; adds the check-in the employee forgot (at p_time, same local day,
--   before the check-out and after the employee's previous event) and closes a session around the pair.
create or replace function public.admin_resolve_review(p_event_id uuid, p_action text, p_time timestamp with time zone default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_admin uuid := (select auth.uid());
  v_ev public.attendance_events;
  v_tz text;
  v_in_id uuid;
  v_review jsonb;
begin
  if p_action is null or p_action not in ('accept', 'add_check_in') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id and ev.company_id = v_company;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  -- Same lock order as record_punch (employee first), so a resolve and a punch of the same employee cannot deadlock.
  perform 1 from public.employees e where e.id = v_ev.employee_id for update;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id for update;
  if not v_ev.needs_review then
    raise exception 'already_resolved' using errcode = 'P0001';
  end if;
  select c.timezone into v_tz from public.companies c where c.id = v_company;
  v_review := jsonb_build_object('action', p_action, 'by', v_admin, 'at', now(), 'note', left(nullif(trim(coalesce(p_note, '')), ''), 500));

  if p_action = 'add_check_in' then
    if v_ev.event_type <> 'check_out' or not coalesce(v_ev.metadata -> 'suspect' ? 'missing_checkin', false) then
      raise exception 'invalid_action' using errcode = '22023';
    end if;
    if p_time is null or p_time >= v_ev.occurred_at
       or (p_time at time zone v_tz)::date <> (v_ev.occurred_at at time zone v_tz)::date
       or exists (select 1 from public.attendance_events x where x.employee_id = v_ev.employee_id
                  and x.id <> v_ev.id and x.occurred_at >= p_time and x.occurred_at <= v_ev.occurred_at) then
      raise exception 'invalid_time' using errcode = 'P0001';
    end if;
    insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method,
                                          location_status, needs_review, location_policy, metadata)
    values (v_ev.employee_id, 'check_in', p_time, true, 'admin', 'not_requested', false, 'none',
            jsonb_build_object('source', 'admin_correction', 'corrects_event', v_ev.id, 'review', v_review))
    returning id into v_in_id;
    insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, check_out_event_id, status)
    values (v_ev.employee_id, (p_time at time zone v_tz)::date, v_in_id, v_ev.id, 'closed');
  end if;

  update public.attendance_events
     set needs_review = false, metadata = metadata || jsonb_build_object('review', v_review)
   where id = v_ev.id;
  perform public.audit_write(v_company, 'attendance.review_' || p_action, 'attendance_event', v_ev.id::text,
    jsonb_build_object('employee_id', v_ev.employee_id, 'event_type', v_ev.event_type, 'occurred_at', v_ev.occurred_at,
                       'added_check_in', v_in_id, 'added_at', case when v_in_id is null then null else p_time end, 'note', v_review -> 'note'));
  return jsonb_build_object('event_id', v_ev.id, 'action', p_action, 'check_in_event_id', v_in_id);
end;
$$;
revoke all on function public.admin_resolve_review(uuid, text, timestamp with time zone, text) from public, anon;
grant execute on function public.admin_resolve_review(uuid, text, timestamp with time zone, text) to authenticated;
