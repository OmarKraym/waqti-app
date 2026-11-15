-- Phase 25: automatic punch-button mode. Runs inside one transaction and always ends with an exception, so nothing is kept.
-- Run with: psql -v admin_email=<company admin email> -f phase25_auto_punch_mode_tests.sql
-- Rule under test (companies.auto_punch_mode, ships OFF):
--   expected = check_out only when the employee has an open check-in TODAY (local date) and now >= flip time, else check_in.
--   flip time = middle of today's shift (start + (end - start) / 2), or the exit time of an approved early-leave permission if earlier.
--   The shift day resets at 00:00 company time (the schema allows no overnight shifts: end_time > start_time).
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid, app jsonb default '{}') returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated', 'app_metadata', app)::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
-- an open session whose check-in happened at p_at
create function pg_temp.open_session(e uuid, p_at timestamptz, p_tz text) returns uuid language plpgsql as $$
declare v_ev uuid; v_s uuid;
begin
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (e, 'check_in', p_at, true, 'password', 'none') returning id into v_ev;
  insert into public.attendance_sessions (employee_id, work_date, check_in_event_id, status)
  values (e, (p_at at time zone p_tz)::date, v_ev, 'open') returning id into v_s;
  return v_ev;
end $$;
create function pg_temp.sched(e uuid, comp uuid, st time, en time) returns void language plpgsql as $$
begin
  delete from public.employee_work_schedules where employee_id = e;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select e, g, st is not null, st, en, comp from generate_series(0, 6) g;
end $$;
create function pg_temp.sched_mid(e uuid, comp uuid, tz text, off interval) returns boolean language plpgsql as $$
declare m time; w interval;
begin
  if (now() at time zone tz)::time not between time '01:30' and time '22:30' then return false; end if;
  m := (now() at time zone tz)::time + off;
  w := least(m - time '00:00', time '23:59:59' - m, interval '2 hours');
  perform pg_temp.sched(e, comp, m - w, m + w);
  return true;
end $$;
create function pg_temp.punch(e uuid, tz text, act text, p_at timestamptz) returns text language plpgsql as $$
begin
  perform private.record_punch(e, 'none', 'reject', 100, tz, gen_random_uuid(), act, 'not_requested', null, null, null, p_at, '{}'::jsonb);
  return '';
exception when others then return sqlerrm; end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; h uuid; f uuid; g uuid; v_comp uuid; v_tz text; r jsonb; s text; d1 date;
  v_ev uuid;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 0 limit 1;
  select id into b from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 1 limit 1;
  select id into c from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 2 limit 1;
  select id into h from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 3 limit 1;
  select id into f from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 4 limit 1;
  select id into g from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 5 limit 1;
  d1 := (now() at time zone v_tz)::date + 7;
  update public.employees set location_policy = 'none' where id in (a, b, c, h, f, g);

  -- ------------------------------------------------------------ the switch: off by default, admin only, audited
  perform pg_temp.ok(not (select auto_punch_mode from public.companies where id = v_comp), 'auto_punch_mode is OFF by default');
  perform pg_temp.as_user(v_admin);
  r := public.admin_get_auto_punch_mode();
  perform pg_temp.ok(r ->> 'enabled' = 'false', 'admin reads the switch (off)', r::text);
  perform pg_temp.as_user(a);
  s := pg_temp.err('select public.admin_set_auto_punch_mode(true)');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot change the switch', s);
  s := pg_temp.err('select public.admin_get_auto_punch_mode()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot read the switch', s);
  perform pg_temp.ok(not (select auto_punch_mode from public.companies where id = v_comp), 'still off after the refused call');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.punch_mode(uuid, timestamp with time zone)', 'execute')
                     and not has_function_privilege('authenticated', 'private.expected_punch_type(uuid, timestamp with time zone)', 'execute'),
                     'punch_mode and expected_punch_type are private');

  -- ------------------------------------------------------------ the rule, employee A: shift 08:00-16:00 -> flips at 12:00
  perform pg_temp.sched(a, v_comp, time '08:00', time '16:00');
  perform pg_temp.ok(private.expected_punch_type(a, (d1 + time '07:00') at time zone v_tz) = 'check_in', 'no session 07:00 -> check_in');
  perform pg_temp.ok(private.expected_punch_type(a, (d1 + time '13:00') at time zone v_tz) = 'check_in',
                     'late arrival: no session at 13:00 -> check_in (never check_out)');
  perform pg_temp.ok(private.expected_punch_type(a, (d1 + time '23:59') at time zone v_tz) = 'check_in', 'no session 23:59 -> check_in');
  perform pg_temp.open_session(a, (d1 + time '08:05') at time zone v_tz, v_tz);
  r := private.punch_mode(a, (d1 + time '11:59') at time zone v_tz);
  perform pg_temp.ok(r ->> 'expected' = 'check_in' and (r ->> 'locked')::boolean, '11:59 with an open check-in -> check_in, locked', r::text);
  r := private.punch_mode(a, (d1 + time '12:00') at time zone v_tz);
  perform pg_temp.ok(r ->> 'expected' = 'check_out' and not (r ->> 'locked')::boolean, '12:00 exactly -> check_out (inclusive)', r::text);
  perform pg_temp.ok(private.expected_punch_type(a, (d1 + time '15:59') at time zone v_tz) = 'check_out', '15:59 with an open check-in -> check_out');
  perform pg_temp.ok(private.expected_punch_type(a, (d1 + time '20:00') at time zone v_tz) = 'check_out', 'after the shift, still open the same day -> check_out');
  r := private.punch_mode(a, (d1 + time '11:59') at time zone v_tz);
  perform pg_temp.ok((r ->> 'flips_at')::timestamptz = (d1 + time '12:00') at time zone v_tz
                     and (r ->> 'reset_at')::timestamptz = (d1 + 1) at time zone v_tz
                     and (r ->> 'shift_start')::timestamptz = (d1 + time '08:00') at time zone v_tz
                     and (r ->> 'shift_end')::timestamptz = (d1 + time '16:00') at time zone v_tz, 'flip time 12:00, reset at 00:00 next day', r::text);
  r := private.punch_mode(a, (d1 + 1) at time zone v_tz);
  perform pg_temp.ok(r ->> 'expected' = 'check_in' and (r ->> 'stale_open')::boolean, 'at 00:00 the day resets -> check_in (the open check-in is stale)', r::text);
  perform pg_temp.ok(private.expected_punch_type(a, ((d1 + 1) + time '14:00') at time zone v_tz) = 'check_in',
                     'next day 14:00 with yesterday''s open check-in -> check_in (stale does not block)');

  -- ------------------------------------------------------------ other shifts: the middle is computed from the employee's own hours
  perform pg_temp.sched(b, v_comp, time '09:00', time '17:00');
  perform pg_temp.open_session(b, (d1 + time '09:05') at time zone v_tz, v_tz);
  perform pg_temp.ok(private.expected_punch_type(b, (d1 + time '12:59') at time zone v_tz) = 'check_in'
                     and private.expected_punch_type(b, (d1 + time '13:00') at time zone v_tz) = 'check_out', '09:00-17:00 flips at 13:00');
  perform pg_temp.sched(c, v_comp, time '08:30', time '16:45');
  perform pg_temp.open_session(c, (d1 + time '08:35') at time zone v_tz, v_tz);
  r := private.punch_mode(c, (d1 + time '12:37') at time zone v_tz);
  perform pg_temp.ok((r ->> 'flips_at')::timestamptz = (d1 + time '12:37:30') at time zone v_tz and r ->> 'expected' = 'check_in',
                     '08:30-16:45 flips at 12:37:30 (not rounded)', r::text);
  perform pg_temp.ok(private.expected_punch_type(c, (d1 + time '12:37:30') at time zone v_tz) = 'check_out', '12:37:30 -> check_out');

  -- ------------------------------------------------------------ an approved early-leave permission flips earlier (no dead end before the middle)
  insert into public.permission_types (company_id, name, mode, days_back, days_ahead) values (v_comp, 'p25 early', 'early_leave', 30, 30);
  insert into public.requests (employee_id, request_type, status, start_at, end_at, company_id, permission_type_id)
  select a, 'permission', 'approved', (d1 + time '10:30') at time zone v_tz, (d1 + time '16:00') at time zone v_tz, v_comp, id
  from public.permission_types where company_id = v_comp and name = 'p25 early';
  perform pg_temp.ok(private.expected_punch_type(a, (d1 + time '10:29') at time zone v_tz) = 'check_in'
                     and private.expected_punch_type(a, (d1 + time '10:30') at time zone v_tz) = 'check_out', 'early leave 10:30: flips at 10:30');
  perform pg_temp.ok((private.punch_mode(a, (d1 + time '10:00') at time zone v_tz) ->> 'flips_at')::timestamptz = (d1 + time '10:30') at time zone v_tz,
                     'flips_at reports the permission time');
  perform pg_temp.ok(private.expected_punch_type(b, (d1 + time '10:30') at time zone v_tz) = 'check_in', 'the permission of A does not move B');

  -- ------------------------------------------------------------ no shift today
  perform pg_temp.sched(h, v_comp, null, null);
  perform pg_temp.ok(private.expected_punch_type(h, (d1 + time '10:00') at time zone v_tz) = 'check_in', 'day off, no session -> check_in');
  perform pg_temp.open_session(h, (d1 + time '09:00') at time zone v_tz, v_tz);
  r := private.punch_mode(h, (d1 + time '10:00') at time zone v_tz);
  perform pg_temp.ok(r ->> 'expected' = 'check_out' and r ->> 'reason' = 'no_shift', 'day off, open session today -> check_out (no shift: no middle)', r::text);

  -- ------------------------------------------------------------ the server enforces it (switch ON)
  perform pg_temp.as_user(v_admin);
  r := public.admin_set_auto_punch_mode(true);
  perform pg_temp.ok(r ->> 'enabled' = 'true' and (select auto_punch_mode from public.companies where id = v_comp), 'admin turns it on', r::text);
  perform pg_temp.ok(exists (select 1 from public.audit_log where company_id = v_comp and action = 'company.auto_punch_mode'), 'the change is audited');
  perform pg_temp.ok((public.admin_get_auto_punch_mode() ->> 'enabled') = 'true', 'switch reads back on');

  perform pg_temp.sched(f, v_comp, time '08:00', time '16:00');
  s := pg_temp.punch(f, v_tz, 'check_in', (d1 + time '08:05') at time zone v_tz);
  perform pg_temp.ok(s = '', 'ON: check-in 08:05 accepted', s);
  s := pg_temp.punch(f, v_tz, 'check_out', (d1 + time '10:00') at time zone v_tz);
  perform pg_temp.ok(s = 'mode_mismatch', 'ON: check-out before the middle refused (mode_mismatch)', s);
  s := pg_temp.punch(f, v_tz, 'check_in', (d1 + time '10:01') at time zone v_tz);
  perform pg_temp.ok(s = 'state_changed', 'ON: a second check-in while one is open refused (state_changed)', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = f) = 1, 'ON: the refused punches saved nothing');
  s := pg_temp.punch(f, v_tz, 'check_out', (d1 + time '12:00') at time zone v_tz);
  perform pg_temp.ok(s = '', 'ON: check-out at 12:00 accepted', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = f and event_type = 'check_out') = 1, 'ON: the check-out is in the log');

  -- late arrival: the middle has passed but there is no check-in -> the button is check-in, a check-out is refused
  perform pg_temp.sched(g, v_comp, time '08:00', time '16:00');
  s := pg_temp.punch(g, v_tz, 'check_out', (d1 + time '13:00') at time zone v_tz);
  perform pg_temp.ok(s = 'mode_mismatch', 'ON: check-out at 13:00 without a check-in refused (no orphan check-out)', s);
  s := pg_temp.punch(g, v_tz, 'check_in', (d1 + time '13:00:05') at time zone v_tz);
  perform pg_temp.ok(s = '', 'ON: late arrival at 13:00 is recorded as a check-in', s);

  -- a stale open check-in (yesterday) does not block today's check-in; it is flagged, never closed with an invented time
  delete from public.attendance_sessions where employee_id = h;
  delete from public.attendance_events where employee_id = h;
  perform pg_temp.sched(h, v_comp, time '08:00', time '16:00');
  v_ev := pg_temp.open_session(h, ((d1 - 1) + time '08:05') at time zone v_tz, v_tz);
  s := pg_temp.punch(h, v_tz, 'check_in', (d1 + time '08:00') at time zone v_tz);
  perform pg_temp.ok(s = '', 'ON: check-in the next day accepted although yesterday is still open', s);
  perform pg_temp.ok((select status::text from public.attendance_sessions where check_in_event_id = v_ev) = 'missed_checkout', 'stale session marked missed_checkout');
  perform pg_temp.ok((select needs_review and (metadata ->> 'missed_checkout')::boolean from public.attendance_events where id = v_ev), 'stale check-in flagged for review');
  perform pg_temp.ok(not exists (select 1 from public.attendance_events where employee_id = h and event_type = 'check_out'), 'no check-out was invented');
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = h and status = 'open') = 1, 'today has one open session');

  -- ------------------------------------------------------------ OFF = exactly the old behaviour
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_auto_punch_mode(false);
  perform pg_temp.sched(a, v_comp, time '08:00', time '16:00');
  delete from public.attendance_sessions where employee_id = a;
  delete from public.attendance_events where employee_id = a;
  s := pg_temp.punch(a, v_tz, 'check_in', (d1 + time '08:05') at time zone v_tz);
  perform pg_temp.ok(s = '', 'OFF: check-in accepted', s);
  s := pg_temp.punch(a, v_tz, 'check_out', (d1 + time '10:00') at time zone v_tz);
  perform pg_temp.ok(s = '', 'OFF: check-out before the middle accepted (old behaviour)', s);

  -- ------------------------------------------------------------ the employee's state (now() is the only clock here, so the shift is built around it)
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_auto_punch_mode(true);
  delete from public.attendance_sessions where employee_id = b;
  delete from public.attendance_events where employee_id = b;
  if pg_temp.sched_mid(b, v_comp, v_tz, interval '1 hour') then
    perform pg_temp.open_session(b, now() - interval '30 minutes', v_tz);
    perform pg_temp.as_user(b);
    r := public.employee_attendance_state();
    perform pg_temp.ok(r ->> 'next_action' = 'check_in' and (r -> 'punch_mode' ->> 'auto')::boolean and (r -> 'punch_mode' ->> 'locked')::boolean
                       and r -> 'open_session' <> 'null'::jsonb, 'state: before the middle with an open check-in -> check_in, locked', (r -> 'punch_mode')::text);
    perform pg_temp.ok((r -> 'punch_mode' ->> 'flips_at')::timestamptz = now() + interval '1 hour', 'state: flips_at = the middle of the shift', (r -> 'punch_mode')::text);
    perform pg_temp.ok(not (r ->> 'can_check_out_without_in')::boolean and not (r ->> 'forgot_check_in')::boolean, 'state ON: no check-out without a check-in');
    perform pg_temp.as_user(v_admin);
    perform pg_temp.sched_mid(b, v_comp, v_tz, interval '-1 hour');
    perform pg_temp.as_user(b);
    r := public.employee_attendance_state();
    perform pg_temp.ok(r ->> 'next_action' = 'check_out' and not (r -> 'punch_mode' ->> 'locked')::boolean, 'state: after the middle -> check_out, not locked', (r -> 'punch_mode')::text);
    perform pg_temp.as_user(v_admin);
    perform public.admin_set_auto_punch_mode(false);
    perform pg_temp.as_user(b);
    r := public.employee_attendance_state();
    perform pg_temp.ok(r ->> 'next_action' = 'check_out' and not (r -> 'punch_mode' ->> 'auto')::boolean and not (r -> 'punch_mode' ->> 'locked')::boolean,
                       'state OFF: old next_action, punch_mode.auto false', (r -> 'punch_mode')::text);
  else
    -- within 1.5 h of midnight a shift around "now" would cross the day: the rule itself is covered by the vectors above
    perform pg_temp.ok(true, 'state tests skipped near midnight (company time)');
  end if;

  -- ------------------------------------------------------------ the admin's preview
  perform pg_temp.as_user(v_admin);
  perform pg_temp.sched(a, v_comp, time '08:00', time '16:00');
  r := public.admin_punch_mode_preview(a, (d1 + time '09:00') at time zone v_tz);
  -- A still has the approved early-leave permission (exit 10:30) from above: it flips at 10:30, the middle of the shift stays 12:00.
  perform pg_temp.ok((r ->> 'midpoint')::timestamptz = (d1 + time '12:00') at time zone v_tz
                     and (r ->> 'flips_at')::timestamptz = (d1 + time '10:30') at time zone v_tz and r ->> 'expected' = 'check_in',
                     'preview: the middle of a saved shift and the flip time', r::text);
  s := pg_temp.err(format('select public.admin_punch_mode_preview(%L, null)', gen_random_uuid()));
  perform pg_temp.ok(s = 'employee_not_found', 'preview: unknown employee refused', s);
  perform pg_temp.as_user(a);
  s := pg_temp.err(format('select public.admin_punch_mode_preview(%L, null)', a));
  perform pg_temp.ok(s = 'forbidden', 'preview: employee refused', s);
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
