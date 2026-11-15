-- Phase 27: the admin edits the TIME of one movement.
--   public.admin_edit_punch(event_id, new_time, reason) -> {event_id, event_type, employee_id, previous_time, occurred_at}
--   * Owner only. A limited admin level (phase 26) is refused by default (its allow-list has no row for this function); one insert opens it.
--   * A reason (3..500 letters) is required. The new time must be in the past and at most 62 days back.
--   * The movement keeps its employee, its kind (check-in / check-out), how it was made and its place (session, work day, review flag).
--     Only occurred_at changes, and only inside these limits (anything else is refused and nothing is written):
--       - the same day of the company (day_changed): the work day of the session, the leave day of phase 22 and the day marks of
--         phases 22 / 23 are all kept by the day, so they stay true;
--       - strictly between the employee's previous and next movement (invalid_time): the order of his movements never changes;
--       - a session that has both movements stays longer than zero and at most 24 hours (invalid_time), like admin_add_punch;
--       - a different time from the one it has (no_change).
--   * Lateness, early leave, the deduction (phase 19) and overtime (phase 6) are computed from occurred_at when they are read, so they
--     follow the new time by themselves; nothing stored needs to be recomputed.
--   * What stays on the record: metadata.edited = true, metadata.original_occurred_at (the time before the FIRST edit), and metadata.edits
--     (one line per edit: at, by, from, to, reason). The audit log gets 'attendance.edit_time' with the same facts.
--   * Not in this phase on purpose: changing the kind of a movement, changing its day, deleting it.
-- Nothing existing is changed or deleted. Rollback: 20261115110000_phase27_admin_edit_punch_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('public.require_company_admin()') is null
     or to_regprocedure('public.audit_write(uuid, text, text, text, jsonb)') is null
     or to_regprocedure('public.admin_add_punch(uuid, text, timestamp with time zone, text)') is null
     or to_regclass('public.attendance_sessions') is null then
    raise exception 'phase27: the manual punch phase (20) must be applied first';
  end if;
end
$guard$;

create or replace function public.admin_edit_punch(p_event_id uuid, p_time timestamp with time zone, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_admin uuid := (select auth.uid());
  v_reason text := left(nullif(trim(coalesce(p_reason, '')), ''), 500);
  v_tz text;
  v_ev public.attendance_events;
  v_prev timestamptz;
  v_next timestamptz;
  v_in_at timestamptz;
  v_out_at timestamptz;
begin
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'reason_required' using errcode = '22023';
  end if;
  if p_time is null or p_time > now() or p_time < now() - interval '62 days' then
    raise exception 'invalid_time' using errcode = 'P0001';
  end if;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id and ev.company_id = v_company;
  if not found then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  -- Same lock order as record_punch and admin_add_punch (the employee first), so an edit and a punch of the same employee cannot deadlock.
  perform 1 from public.employees e where e.id = v_ev.employee_id for update;
  select ev.* into v_ev from public.attendance_events ev where ev.id = p_event_id for update;
  select c.timezone into v_tz from public.companies c where c.id = v_company;

  if p_time = v_ev.occurred_at then
    raise exception 'no_change' using errcode = 'P0001';
  end if;
  if (p_time at time zone v_tz)::date <> (v_ev.occurred_at at time zone v_tz)::date then
    raise exception 'day_changed' using errcode = 'P0001';
  end if;
  -- the order of the employee's movements never changes: the new time lies strictly between his previous and his next movement
  select max(x.occurred_at) into v_prev from public.attendance_events x
   where x.employee_id = v_ev.employee_id and x.id <> v_ev.id and x.occurred_at <= v_ev.occurred_at;
  select min(x.occurred_at) into v_next from public.attendance_events x
   where x.employee_id = v_ev.employee_id and x.id <> v_ev.id and x.occurred_at >= v_ev.occurred_at;
  if (v_prev is not null and p_time <= v_prev) or (v_next is not null and p_time >= v_next) then
    raise exception 'invalid_time' using errcode = 'P0001';
  end if;
  -- a closed session stays longer than zero and at most 24 hours
  select ci.occurred_at, co.occurred_at into v_in_at, v_out_at
    from public.attendance_sessions s
    join public.attendance_events ci on ci.id = s.check_in_event_id
    left join public.attendance_events co on co.id = s.check_out_event_id
   where s.check_in_event_id = v_ev.id or s.check_out_event_id = v_ev.id
   limit 1;
  if found and v_out_at is not null then
    if v_ev.event_type = 'check_in' then v_in_at := p_time; else v_out_at := p_time; end if;
    if v_out_at <= v_in_at or v_out_at > v_in_at + interval '24 hours' then
      raise exception 'invalid_time' using errcode = 'P0001';
    end if;
  end if;

  update public.attendance_events
     set occurred_at = p_time,
         metadata = metadata || jsonb_build_object(
           'edited', true,
           'original_occurred_at', coalesce(metadata -> 'original_occurred_at', to_jsonb(v_ev.occurred_at)),
           'edits', coalesce(metadata -> 'edits', '[]'::jsonb)
                    || jsonb_build_array(jsonb_build_object('at', now(), 'by', v_admin, 'from', v_ev.occurred_at, 'to', p_time, 'reason', v_reason)))
   where id = v_ev.id;
  update public.attendance_sessions set updated_at = now() where check_in_event_id = v_ev.id or check_out_event_id = v_ev.id;

  perform public.audit_write(v_company, 'attendance.edit_time', 'attendance_event', v_ev.id::text,
    jsonb_build_object('employee_id', v_ev.employee_id, 'event_type', v_ev.event_type, 'from', v_ev.occurred_at, 'to', p_time, 'reason', v_reason));
  return jsonb_build_object('event_id', v_ev.id, 'event_type', v_ev.event_type, 'employee_id', v_ev.employee_id,
                            'previous_time', v_ev.occurred_at, 'occurred_at', p_time);
end;
$$;
revoke all on function public.admin_edit_punch(uuid, timestamp with time zone, text) from public, anon;
grant execute on function public.admin_edit_punch(uuid, timestamp with time zone, text) to authenticated;
