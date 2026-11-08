-- Phase 20: the admin adds a check-in or a check-out the employee forgot (public.admin_add_punch).
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
-- one call of the function as the admin (jwt of the admin, role authenticated), back to the test's own role afterwards
create function pg_temp.add(adm uuid, emp uuid, typ text, at timestamptz, why text default 'نسي التسجيل') returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_add_punch(emp, typ, at, why);
  reset role;
  return r;
end $$;
-- the same, but returns the error text instead of raising
create function pg_temp.add_err(adm uuid, emp uuid, typ text, at timestamptz, why text default 'نسي التسجيل') returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.admin_add_punch(emp, typ, at, why);
    r := '';
  exception when others then r := sqlerrm;
  end;
  reset role;
  return r;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; d uuid; v_inact uuid; v_comp uuid; v_comp2 uuid; v_tz text; v_today date;
  wd date[]; r jsonb; r2 jsonb; r3 jsonb; s text; n int; ev_in uuid; ev_out uuid; sess uuid; e_other uuid; e_orphan uuid; v_old date;
  l record;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) and e.company_id = v_comp order by employee_number limit 1;
  select id into d from public.employees e where e.is_active and e.id not in (v_admin, a, b, c) and e.company_id = v_comp order by employee_number limit 1;
  select id into v_inact from public.employees e where not e.is_active and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone v_tz)::date;
  -- workdays (the seed's week: Friday is the day off) in the last 12 days, newest first
  select array_agg(g::date order by g desc) into wd from generate_series(v_today - 12, v_today - 1, interval '1 day') g where extract(dow from g) <> 5;
  delete from public.attendance_sessions where employee_id in (a, b, c, d, v_inact);
  delete from public.attendance_events where employee_id in (a, b, c, d, v_inact);
  update public.companies set late_grace_min = 15, early_grace_min = 10, late_rule = 'all_after_grace', punch_windows_enabled = false where id = v_comp;
  update public.employees set late_grace_min = null, early_grace_min = null where id in (a, b, c, d);

  -- ---------------------------------------------------------------- who may call it
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_add_punch(uuid, text, timestamptz, text)', 'execute'), 'anon cannot execute it');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_add_punch(uuid, text, timestamptz, text)', 'execute'), 'authenticated can (the function checks the admin itself)');
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_add_punch(%L, ''check_in'', %L, ''x y z'')', a, (wd[1] + time '08:20') at time zone v_tz));
  reset role;
  perform pg_temp.ok(s <> '' and s <> 'x', 'an employee cannot use it', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = a) = 0, 'and nothing was written');

  -- ---------------------------------------------------------------- validation
  s := pg_temp.add_err(v_admin, a, 'delete', (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'unknown type refused', s);
  s := pg_temp.add_err(v_admin, a, null, (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_action', 'no type refused', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', (wd[1] + time '08:20') at time zone v_tz, null);
  perform pg_temp.ok(s = 'reason_required', 'a reason is required (null)', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', (wd[1] + time '08:20') at time zone v_tz, '   ');
  perform pg_temp.ok(s = 'reason_required', 'a reason is required (blank)', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', (wd[1] + time '08:20') at time zone v_tz, 'ab');
  perform pg_temp.ok(s = 'reason_required', 'a reason of two letters is too short', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', null);
  perform pg_temp.ok(s = 'invalid_time', 'a time is required', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', now() + interval '5 minutes');
  perform pg_temp.ok(s = 'invalid_time', 'a time in the future is refused', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', now() - interval '63 days');
  perform pg_temp.ok(s = 'invalid_time', 'more than 62 days back is refused', s);
  s := pg_temp.add_err(v_admin, gen_random_uuid(), 'check_in', (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'an unknown employee', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = a) = 0, 'a refused call writes nothing');

  -- another company's employee is invisible and untouchable
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'manual-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e_other;
  s := pg_temp.add_err(v_admin, e_other, 'check_in', (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'an employee of another company', s);

  -- ---------------------------------------------------------------- a check-in on an earlier day, nothing after it
  r := pg_temp.add(v_admin, a, 'check_in', (wd[1] + time '08:20') at time zone v_tz, '  نسي البصمة صباحًا  ');
  ev_in := (r ->> 'event_id')::uuid;
  sess := (r ->> 'session_id')::uuid;
  perform pg_temp.ok(r ->> 'event_type' = 'check_in' and r ->> 'session_status' = 'missed_checkout', 'earlier day, no check-out: the session is "missed_checkout"', r::text);
  perform pg_temp.ok((select e.authentication_method = 'admin' and e.location_status = 'not_requested' and e.location_policy = 'none'
                             and e.within_geofence and e.metadata ->> 'source' = 'admin_manual'
                             and e.metadata ->> 'reason' = 'نسي البصمة صباحًا' and (e.metadata ->> 'added_by')::uuid = v_admin
                      from public.attendance_events e where e.id = ev_in),
                     'the event says who added it, why (trimmed), no location, source admin_manual');
  perform pg_temp.ok((select e.occurred_at = (wd[1] + time '08:20') at time zone v_tz from public.attendance_events e where e.id = ev_in), 'at the time given');
  perform pg_temp.ok((select s.status = 'missed_checkout' and s.check_out_event_id is null and s.check_in_event_id = ev_in and s.work_date = wd[1]
                      from public.attendance_sessions s where s.id = sess), 'the session is for that work day with no check-out');
  perform pg_temp.ok((select e.needs_review and (e.metadata ->> 'missed_checkout')::boolean from public.attendance_events e where e.id = ev_in),
                     'the check-in is flagged for review like any missed check-out');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.manual_add' and target_id = ev_in::text
                            and details ->> 'reason' = 'نسي البصمة صباحًا' and details ->> 'event_type' = 'check_in') = 1, 'it is in the audit log');

  -- the attendance list: counted by the time written (rule a): 08:20 against 08:00 with grace 15 = 20 minutes late
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into l from public.admin_list_attendance(null, null, a, null, 50, 0) x where x.event_id = ev_in;
  reset role;
  perform pg_temp.ok(l.late_minutes = 20 and l.source = 'admin_manual' and l.missed_checkout, 'the list counts it like a normal punch (20 min late) and shows the source', row(l.late_minutes, l.source, l.missed_checkout)::text);

  -- ---------------------------------------------------------------- the matching check-out
  s := pg_temp.add_err(v_admin, a, 'check_out', (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-out at the same minute as the check-in is refused', s);
  s := pg_temp.add_err(v_admin, a, 'check_out', (wd[1] + time '07:00') at time zone v_tz);
  perform pg_temp.ok(s = 'no_open_session', 'a check-out before the check-in has nothing to close', s);
  s := pg_temp.add_err(v_admin, a, 'check_out', (wd[1] + time '08:20') at time zone v_tz + interval '24 hours 1 minute');
  perform pg_temp.ok(s = 'invalid_time', 'more than 24 hours after the check-in is refused', s);
  r2 := pg_temp.add(v_admin, a, 'check_out', (wd[1] + time '15:30') at time zone v_tz, 'نسي الانصراف');
  ev_out := (r2 ->> 'event_id')::uuid;
  perform pg_temp.ok(r2 ->> 'event_type' = 'check_out' and (r2 ->> 'session_id')::uuid = sess and r2 ->> 'session_status' = 'closed', 'the check-out closes that session', r2::text);
  perform pg_temp.ok((select s.status = 'closed' and s.check_out_event_id = ev_out and s.check_in_event_id = ev_in from public.attendance_sessions s where s.id = sess), 'the session now holds both events');
  perform pg_temp.ok((select e.metadata ->> 'source' = 'admin_manual' and e.authentication_method = 'admin' and not e.needs_review
                             and e.metadata ->> 'reason' = 'نسي الانصراف' and (e.metadata ->> 'added_by')::uuid = v_admin
                             and e.location_status = 'not_requested' and e.location_policy = 'none'
                      from public.attendance_events e where e.id = ev_out), 'the check-out is marked as added by the admin (who, why), has no location and is not flagged');
  perform pg_temp.ok((select not e.needs_review and e.metadata -> 'review' ->> 'action' = 'add_check_out' and (e.metadata -> 'review' ->> 'by')::uuid = v_admin
                             and not coalesce((e.metadata ->> 'missed_checkout')::boolean, false)
                      from public.attendance_events e where e.id = ev_in), 'the "missed check-out" flag on the check-in is cleared and says who did it');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into l from public.admin_list_attendance(null, null, a, null, 50, 0) x where x.event_id = ev_in;
  reset role;
  perform pg_temp.ok(not l.missed_checkout, 'the list no longer shows it as a missed check-out');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.manual_add' and target_id = ev_out::text) = 1, 'the check-out is in the audit log');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into l from public.admin_list_attendance(null, null, a, null, 50, 0) x where x.event_id = ev_out;
  reset role;
  perform pg_temp.ok(l.early_minutes = 30 and l.source = 'admin_manual', 'early leave is counted by the time written too (15:30 vs 16:00, grace 10 = 30)', row(l.early_minutes, l.source)::text);
  s := pg_temp.add_err(v_admin, a, 'check_out', (wd[1] + time '15:40') at time zone v_tz);
  perform pg_temp.ok(s = 'no_open_session', 'a second check-out: the day is already closed', s);

  -- ---------------------------------------------------------------- conflicts with what is already there
  s := pg_temp.add_err(v_admin, a, 'check_in', (wd[1] + time '12:00') at time zone v_tz);
  perform pg_temp.ok(s = 'overlaps_session', 'a check-in inside an existing session is refused', s);
  s := pg_temp.add_err(v_admin, a, 'check_in', (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-in at the exact time of another event is refused', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = a) = 2, 'only the two events exist for a');

  -- a second pair on the same day, outside the first one, is fine: in the evening (later events: none, earlier day: missed_checkout) then out
  r := pg_temp.add(v_admin, a, 'check_in', (wd[1] + time '18:00') at time zone v_tz, 'عمل إضافي مساءً');
  perform pg_temp.ok(r ->> 'session_status' = 'missed_checkout', 'an evening check-in on an earlier day waits for its check-out', r::text);
  r2 := pg_temp.add(v_admin, a, 'check_out', (wd[1] + time '20:00') at time zone v_tz, 'عمل إضافي مساءً');
  perform pg_temp.ok(r2 ->> 'session_status' = 'closed' and (r2 ->> 'session_id') = (r ->> 'session_id'), 'and the check-out closes THAT session, not the morning one', r2::text);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = a and status = 'closed') = 2, 'two closed sessions that day');

  -- ---------------------------------------------------------------- an earlier check-in when later events exist: it waits for its check-out
  r := pg_temp.add(v_admin, a, 'check_in', (wd[1] + time '06:00') at time zone v_tz, 'وصل مبكرًا');
  perform pg_temp.ok(r ->> 'session_status' = 'missed_checkout', 'a check-in before later events cannot be "open"', r::text);
  s := pg_temp.add_err(v_admin, a, 'check_out', (wd[1] + time '09:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-out after another event of the same employee is refused (it would swallow it)', s);
  r2 := pg_temp.add(v_admin, a, 'check_out', (wd[1] + time '07:30') at time zone v_tz, 'وصل مبكرًا');
  perform pg_temp.ok(r2 ->> 'session_status' = 'closed' and (r2 ->> 'session_id') = (r ->> 'session_id'), 'a check-out before the next event closes it', r2::text);

  -- ---------------------------------------------------------------- today: still at work, so the session stays open
  r := pg_temp.add(v_admin, b, 'check_in', now() - interval '1 hour', 'نسي التسجيل عند الوصول');
  perform pg_temp.ok(r ->> 'session_status' = 'open', 'today, nothing after it: an open session', r::text);
  perform pg_temp.ok((select not e.needs_review from public.attendance_events e where e.id = (r ->> 'event_id')::uuid), 'not flagged: the employee is still at work');
  s := pg_temp.add_err(v_admin, b, 'check_in', now() - interval '30 minutes');
  perform pg_temp.ok(s = 'open_session', 'a second check-in while one is open is refused', s);
  s := pg_temp.add_err(v_admin, b, 'check_in', now() - interval '2 hours');
  perform pg_temp.ok(s = 'open_session', 'even one before the open check-in is refused', s);
  -- the employee himself can check out now (his own state sees the open session)
  perform pg_temp.as_user(b);
  set local role authenticated;
  r2 := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(r2 -> 'open_session' is not null and r2 -> 'open_session' <> 'null'::jsonb, 'the employee''s own state shows the open session', r2::text);
  r2 := pg_temp.add(v_admin, b, 'check_out', now() - interval '5 minutes', 'انصرف ولم يسجل');
  perform pg_temp.ok(r2 ->> 'session_status' = 'closed', 'the admin closes it', r2::text);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = b and status = 'open') = 0, 'no open session is left');
  -- still today, but events come after it (his session an hour ago): it cannot be "open", it waits for its check-out
  r := pg_temp.add(v_admin, b, 'check_in', now() - interval '3 hours', 'نسي التسجيل صباحًا');
  perform pg_temp.ok(r ->> 'session_status' = 'missed_checkout', 'today, but later events exist: it waits for its check-out (not "open")', r::text);
  r2 := pg_temp.add(v_admin, b, 'check_out', now() - interval '2 hours', 'نسي الانصراف');
  perform pg_temp.ok(r2 ->> 'session_status' = 'closed' and r2 ->> 'session_id' = r ->> 'session_id', 'and it closes with its own check-out', r2::text);

  -- ---------------------------------------------------------------- a check-in right before an unpaired check-out: use the review queue
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, needs_review, location_status, authentication_method, metadata)
  values (c, 'check_out', (wd[2] + time '15:00') at time zone v_tz, true, true, 'not_requested', 'password', '{"suspect":["missing_checkin"]}') returning id into e_orphan;
  s := pg_temp.add_err(v_admin, c, 'check_in', (wd[2] + time '08:00') at time zone v_tz);
  perform pg_temp.ok(s = 'unpaired_checkout', 'the next event is a check-out with no check-in: handle it in the review queue', s);
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = c) = 1, 'nothing was added');
  -- but a check-in on another day, with that orphan far after it, is fine
  r := pg_temp.add(v_admin, c, 'check_in', (wd[4] + time '08:00') at time zone v_tz);
  perform pg_temp.ok(r ->> 'event_type' = 'check_in', 'a check-in on an earlier day than the orphan is accepted', r::text);

  -- ---------------------------------------------------------------- a deactivated employee: history can still be completed (payroll)
  r := pg_temp.add(v_admin, v_inact, 'check_in', (wd[3] + time '08:00') at time zone v_tz, 'استكمال سجل موظف منتهٍ');
  perform pg_temp.ok(r ->> 'event_type' = 'check_in', 'an inactive employee''s history can be completed', r::text);

  -- ---------------------------------------------------------------- two forgotten pairs, the check-outs come after both check-ins
  r := pg_temp.add(v_admin, d, 'check_in', (wd[5] + time '07:00') at time zone v_tz, 'الصباح');
  r2 := pg_temp.add(v_admin, d, 'check_in', (wd[5] + time '18:00') at time zone v_tz, 'المساء');
  perform pg_temp.ok(r ->> 'session_status' = 'missed_checkout' and r2 ->> 'session_status' = 'missed_checkout' and r ->> 'session_id' <> r2 ->> 'session_id',
                     'two waiting check-ins, two sessions', r::text || ' / ' || r2::text);
  r3 := pg_temp.add(v_admin, d, 'check_out', (wd[5] + time '20:00') at time zone v_tz, 'المساء');
  perform pg_temp.ok(r3 ->> 'session_id' = r2 ->> 'session_id', 'a check-out goes to the LATEST check-in before it (the evening one)', r3::text);
  r3 := pg_temp.add(v_admin, d, 'check_out', (wd[5] + time '08:00') at time zone v_tz, 'الصباح');
  perform pg_temp.ok(r3 ->> 'session_id' = r ->> 'session_id', 'and the morning check-out goes to the morning one', r3::text);
  perform pg_temp.ok((select count(*) from public.attendance_sessions where employee_id = d and status = 'closed') = 2, 'both sessions are closed');

  -- ---------------------------------------------------------------- it does not change anything it should not
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = (select id from public.employees e
                        where e.is_active and e.id not in (v_admin, a, b, c, d) and e.company_id = v_comp order by employee_number limit 1)) = 0,
                     'an employee nobody touched has no events');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.manual_add') = 16,
                     'one audit row per accepted call (a: 6, b: 4, c: 1, inactive: 1, d: 4) and none for the refused ones',
                     (select count(*)::text from public.audit_log where action = 'attendance.manual_add'));
  perform pg_temp.ok(true, 'END part 1');
end
$tests$;

-- ---------------------------------------------------------------- part 2: the employee sees which movements the admin added
do $tests2$
declare
  v_admin uuid; v_comp uuid; v_tz text; e uuid; v_today date; wd date[]; st jsonb; r jsonb; ev jsonb; n_admin int; n_own int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into e from public.employees x where x.is_active and x.company_id = v_comp and x.id <> v_admin
    and not exists (select 1 from public.attendance_events y where y.employee_id = x.id) order by employee_number limit 1;
  v_today := (now() at time zone v_tz)::date;
  select array_agg(g::date order by g desc) into wd from generate_series(v_today - 12, v_today - 1, interval '1 day') g where extract(dow from g) <> 5;
  update public.employees set location_policy = 'none' where id = e;
  -- his own punch with the password (an older day), then a pair the admin added on a later day
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (e, 'check_in', (wd[4] + time '08:00') at time zone v_tz, true, 'password', 'not_requested', false, 'none', '{}'::jsonb);
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (e, 'check_out', (wd[4] + time '15:00') at time zone v_tz, true, 'password', 'not_requested', false, 'none', '{}'::jsonb);
  r := pg_temp.add(v_admin, e, 'check_in', (wd[2] + time '08:30') at time zone v_tz, 'نسي البصمة');
  r := pg_temp.add(v_admin, e, 'check_out', (wd[2] + time '15:00') at time zone v_tz, 'نسي الانصراف');

  perform pg_temp.as_user(e);
  set local role authenticated;
  st := public.employee_attendance_state();
  reset role;
  perform pg_temp.ok(jsonb_array_length(st -> 'recent_events') = 4, 'the employee gets his four movements', (st -> 'recent_events')::text);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(st -> 'recent_events') x where jsonb_typeof(x -> 'by_admin') is distinct from 'boolean'),
                     'every movement says by_admin (true or false, never missing)');
  select count(*) filter (where (x ->> 'by_admin')::boolean), count(*) filter (where not (x ->> 'by_admin')::boolean)
    into n_admin, n_own from jsonb_array_elements(st -> 'recent_events') x;
  perform pg_temp.ok(n_admin = 2 and n_own = 2, 'two were added by the admin, two are his own', n_admin || ' / ' || n_own);
  perform pg_temp.ok((select bool_and((x ->> 'by_admin')::boolean = ((x ->> 'server_time')::timestamptz >= (wd[2] + time '00:00') at time zone v_tz
                                                                    and (x ->> 'server_time')::timestamptz < (wd[2] + 1 + time '00:00') at time zone v_tz))
                      from jsonb_array_elements(st -> 'recent_events') x),
                     'the flag is true exactly on the two the admin added');
  perform pg_temp.ok(st -> 'recent_events' -> 0 ? 'id' and st -> 'recent_events' -> 0 ? 'action' and st -> 'recent_events' -> 0 ? 'server_time'
                     and st -> 'recent_events' -> 0 ? 'location_status' and st -> 'recent_events' -> 0 ? 'needs_review',
                     'the five old keys are still there');
  perform pg_temp.ok(st ? 'next_action' and st ? 'punch_window' and st ? 'time_token' and st ? 'biometric' and st ? 'forgot_check_in'
                     and st ? 'can_check_out_without_in' and st ? 'open_session', 'the rest of the state is unchanged');
  perform pg_temp.ok(true, 'END part 2');
end
$tests2$;

do $report$
declare v text;
begin
  -- a block that stopped on an error must show as a failure, not as fewer passes
  insert into t_res (name, ok, detail) select 'part ' || blk.k || ' did not finish', false, 'a block stopped on an error' from generate_series(1, 2) blk(k)
  where not exists (select 1 from t_res where t_res.name = 'END part ' || blk.k);
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
