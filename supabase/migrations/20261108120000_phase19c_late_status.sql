-- Phase 19c: what the employee sees right after a check-in, and a race-proof monthly limit.
--   * public.employee_late_status(event) : for the caller's OWN check-in, says how late it was, what counts after the grace and
--     the company rule, the expected deduction (if the company has a policy), and whether the app should offer the late-arrival
--     justification (and why not). It only reads. The app asks it right after a punch (also for a punch that was saved offline and
--     synced later: the answer depends on the time of the punch, never on when it arrived).
--   * private.requests_limit_guard + trigger : a pending permission request cannot push the month over the type's limit, even if
--     two inserts run at the same moment or a future function forgets to check. employee_submit_request already serialises one
--     employee with a row lock (and keeps its own friendly check); this is the last line of defence at the table.
-- Nothing is blocked for the employee by the status function: the offer is a hint, the request itself is still checked by
-- employee_submit_request.
-- Rollback: 20261108120000_phase19c_late_status_ROLLBACK.sql
do $guard$
begin
  if to_regprocedure('private.chargeable_minutes(integer, integer, text)') is null
     or to_regprocedure('private.late_deduction(uuid, date, integer)') is null
     or to_regprocedure('private.permission_usage(uuid, uuid, date, uuid)') is null
     or to_regprocedure('private.shift_bounds(uuid, date, text)') is null
     or to_regprocedure('public.require_active_employee()') is null then
    raise exception 'phase19c: run phases 19a and 19b first';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- the status of one check-in
-- reason: offer | not_late | within_grace | day_off | not_first | not_check_in | no_type | no_balance | already | too_long | outside_window
--   late_min        raw minutes after the shift start (rounded up, like the attendance list); 0 when it does not apply
--   chargeable_min  what the company rule counts after the grace (same function as the attendance list)
--   deduction_min   minutes of pay the policy deducts for chargeable_min; null when the company has no policy for that day
--                   or the punch is not a first arrival. It does not take a justification into account.
--   remaining       justifications left this month for the first active late-arrival type; null = no monthly limit
--                   (or the question does not apply)
--   offer           true only for reason 'offer'
create or replace function public.employee_late_status(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me record;
  ev record;
  v_grace integer;
  v_rule text;
  v_day date;
  v_today date;
  v_start timestamptz;
  v_end timestamptz;
  v_raw integer := 0;
  v_ch integer := 0;
  v_ded integer;
  v_type public.permission_types;
  v_perm jsonb;
  v_remaining integer;
  v_reason text;
begin
  select * into me from public.require_active_employee();

  select x.id, x.event_type, x.occurred_at into ev
  from public.attendance_events x
  where x.id = p_event_id and x.employee_id = me.employee_id;
  if not found then
    raise exception 'event_not_found' using errcode = '22023';
  end if;

  select coalesce(e.late_grace_min, c.late_grace_min), c.late_rule into v_grace, v_rule
  from public.employees e join public.companies c on c.id = e.company_id
  where e.id = me.employee_id;

  v_day := (ev.occurred_at at time zone me.timezone)::date;
  v_today := (now() at time zone me.timezone)::date;

  -- does it apply at all? (same conditions as private.punch_lateness)
  if ev.event_type <> 'check_in' then
    v_reason := 'not_check_in';
  else
    select s.shift_start, s.shift_end into v_start, v_end from private.shift_bounds(me.employee_id, v_day, me.timezone) s;
    if v_start is null or v_end <= v_start then
      v_reason := 'day_off';
    elsif exists (select 1 from public.attendance_events x
                  where x.employee_id = me.employee_id and x.event_type = 'check_in'
                    and (x.occurred_at at time zone me.timezone)::date = v_day
                    and (x.occurred_at, x.id) < (ev.occurred_at, ev.id)) then
      v_reason := 'not_first';
    end if;
  end if;

  if v_reason is null then
    v_raw := greatest(ceil(extract(epoch from (ev.occurred_at - v_start)) / 60)::integer, 0);
    v_ch := private.chargeable_minutes(v_raw, v_grace, v_rule);
    if exists (select 1 from public.deduction_policies p where p.company_id = me.company_id and p.effective_from <= v_day) then
      v_ded := private.late_deduction(me.company_id, v_day, v_ch);
    end if;
    if v_raw = 0 then
      v_reason := 'not_late';
    elsif v_ch = 0 then
      v_reason := 'within_grace';
    else
      -- late beyond the grace: can he justify it?
      select * into v_type from public.permission_types t
      where t.company_id = me.company_id and t.mode = 'late_arrival' and t.is_active
      order by t.sort_order, t.name
      limit 1;
      if not found then
        v_reason := 'no_type';
      else
        v_perm := private.permission_usage(me.employee_id, v_type.id, date_trunc('month', v_day)::date);
        if v_type.max_per_month is not null then
          v_remaining := greatest(v_type.max_per_month - (v_perm ->> 'used')::integer - (v_perm ->> 'pending')::integer, 0);
        end if;
        if exists (select 1 from public.requests r
                   join public.permission_types pt on pt.id = r.permission_type_id and pt.mode = 'late_arrival'
                   where r.employee_id = me.employee_id and r.request_type = 'permission' and r.status in ('pending', 'approved')
                     and (r.start_at at time zone me.timezone)::date = v_day) then
          v_reason := 'already';
        elsif v_remaining = 0 then
          v_reason := 'no_balance';
        elsif v_type.max_minutes is not null and v_raw > v_type.max_minutes then
          v_reason := 'too_long';
        elsif v_day < v_today - v_type.days_back or v_day > v_today + v_type.days_ahead then
          v_reason := 'outside_window';
        else
          v_reason := 'offer';
        end if;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'event_id', ev.id, 'late_min', v_raw, 'grace_min', v_grace, 'chargeable_min', v_ch, 'deduction_min', v_ded,
    'rule', v_rule, 'remaining', v_remaining, 'offer', v_reason = 'offer', 'reason', v_reason, 'permission', v_perm);
end;
$$;
revoke all on function public.employee_late_status(uuid) from public, anon;
grant execute on function public.employee_late_status(uuid) to authenticated;

-- ---------------------------------------------------------------- the monthly limit at the table
-- Before a PENDING permission request is inserted: one lock per employee, then count the month again (approved + pending of
-- that type, in the month of the request's start) and refuse when the type's limit is reached. Approved / rejected / cancelled
-- rows are never refused here (they do not add a pending request).
create or replace function private.requests_limit_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max smallint;
  v_tz text;
  v_use jsonb;
begin
  select t.max_per_month into v_max from public.permission_types t where t.id = new.permission_type_id;
  perform pg_advisory_xact_lock(hashtextextended('waqti.perm:' || new.employee_id::text, 0));
  if v_max is null then
    return new;                                   -- no monthly limit for this type
  end if;
  select c.timezone into v_tz from public.employees e join public.companies c on c.id = e.company_id where e.id = new.employee_id;
  v_use := private.permission_usage(new.employee_id, new.permission_type_id, date_trunc('month', (new.start_at at time zone v_tz))::date);
  if (v_use ->> 'used')::integer + (v_use ->> 'pending')::integer >= v_max then
    raise exception 'permission_limit' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function private.requests_limit_guard() from public, anon, authenticated;

create trigger requests_limit_guard
  before insert on public.requests
  for each row
  when (new.request_type = 'permission' and new.status = 'pending')
  execute function private.requests_limit_guard();
