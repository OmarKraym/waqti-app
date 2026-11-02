-- Phase 13: an employee who forgot to check in can still check out (flagged for review, no session touched).
-- Run with: psql -v admin_email=<company admin email> -f <this file>   (supabase/local/test-db.sh runs it on a fresh copy)
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
grant all on t_res to public;
grant all on sequence t_res_n_seq to public;
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; r jsonb; st jsonb; s text; t0 timestamptz; n int;
  v_ev record;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  delete from public.attendance_sessions where employee_id in (a, b);
  delete from public.attendance_events where employee_id in (a, b);
  t0 := now();

  -- the state offers it
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok((st ->> 'next_action') = 'check_in' and (st ->> 'can_check_out_without_in')::boolean is true, 'no open session: next is check-in and "check-out without check-in" is offered', st::text);

  -- forgot to check in: the check-out is saved, flagged, and no session appears
  r := private.record_punch(a, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_out', 'not_requested', null, null, null, t0, '{}'::jsonb);
  perform pg_temp.ok(r ->> 'action' = 'check_out' and (r ->> 'missing_checkin')::boolean and (r ->> 'needs_review')::boolean, 'check-out with no check-in is saved and flagged', r::text);
  select * into v_ev from public.attendance_events where id = (r ->> 'event_id')::uuid;
  perform pg_temp.ok(v_ev.event_type = 'check_out' and v_ev.needs_review and v_ev.metadata -> 'suspect' ? 'missing_checkin', 'the event is a check-out, needs_review, suspect has missing_checkin');
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = a) = 0, 'no session was created');

  -- afterwards: next is check-in again, and a second check-out is not offered
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok((st ->> 'next_action') = 'check_in' and (st ->> 'can_check_out_without_in')::boolean is false, 'after it: next is check-in and the offer is gone', st::text);
  s := pg_temp.err(format('select private.record_punch(%L, ''none'', ''flag'', 100, %L, gen_random_uuid(), ''check_out'', ''not_requested'', null, null, null, %L, ''{}''::jsonb)', a, v_tz, t0 + interval '1 minute'));
  perform pg_temp.ok(s = 'state_changed', 'a second check-out the same day is refused (state_changed)', s);

  -- the normal path still works and still closes its session
  r := private.record_punch(a, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, t0 + interval '2 minutes', '{}'::jsonb);
  perform pg_temp.ok(r ->> 'action' = 'check_in' and not (r ->> 'missing_checkin')::boolean and not (r ->> 'needs_review')::boolean, 'a normal check-in is unchanged (no flag)', r::text);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = a and status = 'open') = 1, 'the check-in opened a session');
  r := private.record_punch(a, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_out', 'not_requested', null, null, null, t0 + interval '3 minutes', '{}'::jsonb);
  perform pg_temp.ok(r ->> 'action' = 'check_out' and not (r ->> 'missing_checkin')::boolean and not (r ->> 'needs_review')::boolean, 'a normal check-out is unchanged (no flag)', r::text);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = a and status = 'closed') = 1, 'and it closed the session');
  s := pg_temp.err(format('select private.record_punch(%L, ''none'', ''flag'', 100, %L, gen_random_uuid(), ''check_out'', ''not_requested'', null, null, null, %L, ''{}''::jsonb)', a, v_tz, t0 + interval '4 minutes'));
  perform pg_temp.ok(s = 'state_changed', 'right after a normal check-out, another check-out is refused', s);

  -- a check-in while a session is open is still refused as before
  r := private.record_punch(b, 'none', 'flag', 100, v_tz, gen_random_uuid(), 'check_in', 'not_requested', null, null, null, t0 + interval '5 minutes', '{}'::jsonb);
  s := pg_temp.err(format('select private.record_punch(%L, ''none'', ''flag'', 100, %L, gen_random_uuid(), ''check_in'', ''not_requested'', null, null, null, %L, ''{}''::jsonb)', b, v_tz, t0 + interval '6 minutes'));
  perform pg_temp.ok(s = 'state_changed', 'check-in while a session is open is still state_changed', s);

  -- end to end through the public function, as the employee (biometric 'unsupported' = no fingerprint rule applies here)
  delete from public.attendance_sessions where employee_id = b;
  delete from public.attendance_events where employee_id = b;
  update public.companies set punch_windows_enabled = false where id = v_comp;
  update public.employees set location_policy = 'none' where id = b;
  perform pg_temp.as_user(b);
  set local role authenticated;
  r := public.employee_punch(gen_random_uuid(), 'check_out', 'not_requested', null, null, null, 'unsupported');
  reset role;
  perform pg_temp.ok(r ->> 'action' = 'check_out' and (r ->> 'missing_checkin')::boolean, 'employee_punch: check-out without check-in is accepted and flagged', r::text);
  perform pg_temp.as_user(b);
  set local role authenticated;
  s := pg_temp.err(format('select public.employee_punch(%L, ''check_out'', ''not_requested'', null, null, null, ''unsupported'')', gen_random_uuid()));
  reset role;
  -- (now() is frozen inside one test transaction, so the same-instant guard may answer first)
  perform pg_temp.ok(s in ('state_changed', 'time_order'), 'employee_punch: a second one the same day is refused', s);

  -- punch windows: the check-out window still applies to a check-out without check-in
  delete from public.attendance_sessions where employee_id = a;
  delete from public.attendance_events where employee_id = a;
  update public.companies set punch_windows_enabled = true, out_before_min = 30, out_after_min = 30 where id = v_comp;
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, true, time '08:00', time '16:00', v_comp from generate_series(0, 6) g;
  s := pg_temp.err(format('select private.record_punch(%L, ''none'', ''flag'', 100, %L, gen_random_uuid(), ''check_out'', ''not_requested'', null, null, null, %L, ''{}''::jsonb)', a, v_tz,
    (((now() at time zone v_tz)::date + time '10:00') at time zone v_tz) + interval '0'));
  perform pg_temp.ok(s in ('outside_punch_window', 'time_order'), 'at 10:00 (outside the check-out window) it is refused', s);
  perform pg_temp.as_user(a);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok((st -> 'punch_window' ->> 'allowed') is not null, 'the state still reports the punch window', (st -> 'punch_window')::text);
end
$tests$;

do $report$
declare v text;
begin
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
