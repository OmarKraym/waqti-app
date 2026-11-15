-- Phase 27: the admin edits the TIME of one movement (public.admin_edit_punch).
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
-- add a movement as the admin (phase 20 function), back to the test's own role afterwards
create function pg_temp.add(adm uuid, emp uuid, typ text, at timestamptz, why text default 'نسي التسجيل') returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_add_punch(emp, typ, at, why);
  reset role;
  return r;
end $$;
-- one edit as the admin
create function pg_temp.edit(adm uuid, ev uuid, at timestamptz, why text default 'صُحّح الوقت') returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.admin_edit_punch(ev, at, why);
  reset role;
  return r;
end $$;
-- the same, but returns the error text instead of raising
create function pg_temp.edit_err(adm uuid, ev uuid, at timestamptz, why text default 'صُحّح الوقت') returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.admin_edit_punch(ev, at, why);
    r := '';
  exception when others then r := sqlerrm;
  end;
  reset role;
  return r;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; d uuid; v_comp uuid; v_comp2 uuid; v_tz text; v_today date;
  wd date[]; d1 date; d2 date; r jsonb; s text; n int; l record;
  a_in uuid; a_out uuid; a_sess uuid; b1_in uuid; b1_out uuid; b2_in uuid; b2_out uuid; c_in uuid; c_out uuid; d_in uuid; e_other uuid; ev_other uuid;
  v_before timestamptz; v_snap text;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) and e.company_id = v_comp order by employee_number limit 1;
  select id into d from public.employees e where e.is_active and e.id not in (v_admin, a, b, c) and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone v_tz)::date;
  select array_agg(g::date order by g desc) into wd from generate_series(v_today - 12, v_today - 1, interval '1 day') g where extract(dow from g) <> 5;
  delete from public.attendance_sessions where employee_id in (a, b, c, d);
  delete from public.attendance_events where employee_id in (a, b, c, d);
  update public.companies set late_grace_min = 15, early_grace_min = 10, late_rule = 'all_after_grace', punch_windows_enabled = false where id = v_comp;
  update public.employees set late_grace_min = null, early_grace_min = null where id in (a, b, c, d);

  -- ---------------------------------------------------------------- who may call it
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_edit_punch(uuid, timestamptz, text)', 'execute'), 'anon cannot execute it');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_edit_punch(uuid, timestamptz, text)', 'execute'), 'authenticated can (the function checks the admin itself)');

  -- a day of employee a: check-in 08:20 (20 minutes late with the grace of 15), check-out 16:00
  r := pg_temp.add(v_admin, a, 'check_in', (wd[1] + time '08:20') at time zone v_tz);
  a_in := (r ->> 'event_id')::uuid; a_sess := (r ->> 'session_id')::uuid;
  r := pg_temp.add(v_admin, a, 'check_out', (wd[1] + time '16:00') at time zone v_tz);
  a_out := (r ->> 'event_id')::uuid;

  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_edit_punch(%L, %L, ''شيء ما'')', a_in, (wd[1] + time '08:05') at time zone v_tz));
  reset role;
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot use it', s);
  perform pg_temp.ok((select occurred_at = (wd[1] + time '08:20') at time zone v_tz from public.attendance_events where id = a_in), 'and nothing was written');

  -- ---------------------------------------------------------------- validation (nothing is written by a refused call)
  v_snap := (select md5(string_agg(e.id::text || e.occurred_at::text || e.metadata::text, ',' order by e.id)) from public.attendance_events e where e.employee_id in (a, b, c, d));
  s := pg_temp.edit_err(v_admin, a_in, (wd[1] + time '08:05') at time zone v_tz, null);
  perform pg_temp.ok(s = 'reason_required', 'a reason is required (null)', s);
  s := pg_temp.edit_err(v_admin, a_in, (wd[1] + time '08:05') at time zone v_tz, '   ');
  perform pg_temp.ok(s = 'reason_required', 'a reason is required (blank)', s);
  s := pg_temp.edit_err(v_admin, a_in, (wd[1] + time '08:05') at time zone v_tz, 'ab');
  perform pg_temp.ok(s = 'reason_required', 'a reason of two letters is too short', s);
  s := pg_temp.edit_err(v_admin, a_in, null);
  perform pg_temp.ok(s = 'invalid_time', 'a time is required', s);
  s := pg_temp.edit_err(v_admin, a_in, now() + interval '5 minutes');
  perform pg_temp.ok(s = 'invalid_time', 'a time in the future is refused', s);
  s := pg_temp.edit_err(v_admin, a_in, now() - interval '63 days');
  perform pg_temp.ok(s = 'invalid_time', 'a time more than 62 days back is refused', s);
  s := pg_temp.edit_err(v_admin, gen_random_uuid(), (wd[1] + time '08:05') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'an unknown movement', s);
  s := pg_temp.edit_err(v_admin, null, (wd[1] + time '08:05') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'no movement given', s);
  s := pg_temp.edit_err(v_admin, a_in, (wd[1] + time '08:20') at time zone v_tz);
  perform pg_temp.ok(s = 'no_change', 'the same time is refused', s);
  s := pg_temp.edit_err(v_admin, a_in, ((wd[1] + time '08:05') at time zone v_tz) - interval '1 day');
  perform pg_temp.ok(s = 'day_changed', 'another day is refused (the day of a movement does not change)', s);
  s := pg_temp.edit_err(v_admin, a_in, ((wd[1] + time '08:05') at time zone v_tz) - interval '9 hours');
  perform pg_temp.ok(s = 'day_changed', 'across midnight of the company is another day', s);
  s := pg_temp.edit_err(v_admin, a_in, (wd[1] + time '16:30') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-in cannot move after its own check-out', s);
  s := pg_temp.edit_err(v_admin, a_in, (wd[1] + time '16:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'nor onto the same minute as its check-out', s);
  s := pg_temp.edit_err(v_admin, a_out, (wd[1] + time '07:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-out cannot move before its own check-in', s);
  perform pg_temp.ok(v_snap = (select md5(string_agg(e.id::text || e.occurred_at::text || e.metadata::text, ',' order by e.id)) from public.attendance_events e where e.employee_id in (a, b, c, d)),
                     'every refused call wrote nothing');

  -- another company's movement is invisible and untouchable
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  v_comp2 := public.platform_create_company('شركة اختبار', 'Africa/Tripoli');
  reset role;
  insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
  values (gen_random_uuid(), 'edit-iso@example.com', jsonb_build_object('company_id', v_comp2), '{"full_name":"موظف شركة أخرى"}')
  returning id into e_other;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_status, needs_review, location_policy, metadata)
  values (e_other, 'check_in', (wd[2] + time '10:00') at time zone v_tz, true, 'admin', 'not_requested', false, 'none', '{}'::jsonb)
  returning id into ev_other;
  s := pg_temp.edit_err(v_admin, ev_other, (wd[2] + time '10:05') at time zone v_tz);
  perform pg_temp.ok(s = 'not_found', 'a movement of another company', s);

  -- ---------------------------------------------------------------- a good edit: the check-in of a, 08:20 -> 08:05
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into l from public.admin_list_attendance(null, null, a, null, 50, 0) x where x.event_id = a_in;
  reset role;
  perform pg_temp.ok(l.late_minutes = 20, 'before the edit the list says 20 minutes late', l.late_minutes::text);
  r := pg_temp.edit(v_admin, a_in, (wd[1] + time '08:05') at time zone v_tz, '  الموظف وصل مبكراً والبصمة تأخرت  ');
  perform pg_temp.ok(r ->> 'event_id' = a_in::text and r ->> 'event_type' = 'check_in' and (r ->> 'employee_id')::uuid = a
                     and (r ->> 'previous_time')::timestamptz = (wd[1] + time '08:20') at time zone v_tz
                     and (r ->> 'occurred_at')::timestamptz = (wd[1] + time '08:05') at time zone v_tz, 'the answer names the movement, the old and the new time', r::text);
  perform pg_temp.ok((select e.occurred_at = (wd[1] + time '08:05') at time zone v_tz from public.attendance_events e where e.id = a_in), 'the time is changed');
  perform pg_temp.ok((select e.employee_id = a and e.event_type = 'check_in' and e.authentication_method = 'admin' and e.metadata ->> 'source' = 'admin_manual'
                      from public.attendance_events e where e.id = a_in), 'who, what kind, how and the source stay as they were');
  perform pg_temp.ok((select (e.metadata ->> 'edited')::boolean and (e.metadata ->> 'original_occurred_at')::timestamptz = (wd[1] + time '08:20') at time zone v_tz
                             and jsonb_array_length(e.metadata -> 'edits') = 1
                             and (e.metadata -> 'edits' -> 0 ->> 'reason') = 'الموظف وصل مبكراً والبصمة تأخرت'
                             and ((e.metadata -> 'edits' -> 0 ->> 'by'))::uuid = v_admin
                             and (e.metadata -> 'edits' -> 0 ->> 'from')::timestamptz = (wd[1] + time '08:20') at time zone v_tz
                             and (e.metadata -> 'edits' -> 0 ->> 'to')::timestamptz = (wd[1] + time '08:05') at time zone v_tz
                      from public.attendance_events e where e.id = a_in), 'the event keeps the first time, and each edit with who, when and why (reason trimmed)');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.edit_time' and target_id = a_in::text
                            and details ->> 'reason' = 'الموظف وصل مبكراً والبصمة تأخرت' and (details ->> 'employee_id')::uuid = a) = 1, 'it is in the audit log');
  perform pg_temp.ok((select s.status = 'closed' and s.check_in_event_id = a_in and s.check_out_event_id = a_out and s.work_date = wd[1]
                      from public.attendance_sessions s where s.id = a_sess), 'the session is the same pair on the same work day');
  perform pg_temp.ok((select count(*) from public.attendance_events where employee_id = a) = 2, 'no movement was added');
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  select * into l from public.admin_list_attendance(null, null, a, null, 50, 0) x where x.event_id = a_in;
  reset role;
  perform pg_temp.ok(coalesce(l.late_minutes, 0) = 0 and l.occurred_at = (wd[1] + time '08:05') at time zone v_tz,
                     'the list now counts it by the new time: inside the grace, not late', l.late_minutes::text);

  -- a second edit keeps the FIRST original and adds to the history
  r := pg_temp.edit(v_admin, a_in, (wd[1] + time '08:10') at time zone v_tz, 'تعديل ثانٍ');
  perform pg_temp.ok((select (e.metadata ->> 'original_occurred_at')::timestamptz = (wd[1] + time '08:20') at time zone v_tz and jsonb_array_length(e.metadata -> 'edits') = 2
                             and (e.metadata -> 'edits' -> 1 ->> 'from')::timestamptz = (wd[1] + time '08:05') at time zone v_tz
                      from public.attendance_events e where e.id = a_in), 'a second edit keeps the first original and adds one history line');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.edit_time' and target_id = a_in::text) = 2, 'and a second audit row');

  -- the check-out of the same session
  r := pg_temp.edit(v_admin, a_out, (wd[1] + time '17:15') at time zone v_tz, 'بقي يعمل');
  perform pg_temp.ok((select e.occurred_at = (wd[1] + time '17:15') at time zone v_tz and e.event_type = 'check_out' from public.attendance_events e where e.id = a_out)
                     and (select s.status = 'closed' from public.attendance_sessions s where s.id = a_sess), 'a check-out can be edited too, and the session stays closed');

  -- ---------------------------------------------------------------- neighbours: two sessions in one day of employee b
  r := pg_temp.add(v_admin, b, 'check_in',  (wd[3] + time '08:00') at time zone v_tz); b1_in := (r ->> 'event_id')::uuid;
  r := pg_temp.add(v_admin, b, 'check_out', (wd[3] + time '10:00') at time zone v_tz); b1_out := (r ->> 'event_id')::uuid;
  r := pg_temp.add(v_admin, b, 'check_in',  (wd[3] + time '11:00') at time zone v_tz); b2_in := (r ->> 'event_id')::uuid;
  r := pg_temp.add(v_admin, b, 'check_out', (wd[3] + time '15:00') at time zone v_tz); b2_out := (r ->> 'event_id')::uuid;
  s := pg_temp.edit_err(v_admin, b2_in, (wd[3] + time '09:30') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-in cannot move before the previous check-out', s);
  s := pg_temp.edit_err(v_admin, b2_in, (wd[3] + time '10:00') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'nor onto the same minute as it', s);
  r := pg_temp.edit(v_admin, b2_in, (wd[3] + time '10:30') at time zone v_tz);
  perform pg_temp.ok(r ->> 'occurred_at' is not null, 'but it can move up to just after it');
  s := pg_temp.edit_err(v_admin, b1_out, (wd[3] + time '11:30') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-out cannot move after the next check-in', s);
  r := pg_temp.edit(v_admin, b1_out, (wd[3] + time '10:15') at time zone v_tz);
  perform pg_temp.ok(r ->> 'occurred_at' is not null, 'but it can move up to just before it');
  perform pg_temp.ok((select count(*) = 2 and bool_and(s.status = 'closed') from public.attendance_sessions s where s.employee_id = b), 'both sessions of b are still closed');

  -- ---------------------------------------------------------------- the 24-hour rule of a session that crosses midnight (employee c)
  d1 := v_today - 6; d2 := d1 + 1;
  r := pg_temp.add(v_admin, c, 'check_in',  (d1 + time '23:00') at time zone v_tz); c_in := (r ->> 'event_id')::uuid;
  r := pg_temp.add(v_admin, c, 'check_out', (d2 + time '20:00') at time zone v_tz); c_out := (r ->> 'event_id')::uuid;
  s := pg_temp.edit_err(v_admin, c_in, (d1 + time '00:30') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-in cannot move so that the session is longer than 24 hours', s);
  r := pg_temp.edit(v_admin, c_in, (d1 + time '22:30') at time zone v_tz);
  perform pg_temp.ok(r ->> 'occurred_at' is not null, 'inside 24 hours it can');
  s := pg_temp.edit_err(v_admin, c_out, (d2 + time '23:59') at time zone v_tz);
  perform pg_temp.ok(s = 'invalid_time', 'a check-out cannot move so that the session is longer than 24 hours', s);
  r := pg_temp.edit(v_admin, c_out, (d2 + time '22:00') at time zone v_tz);
  perform pg_temp.ok(r ->> 'occurred_at' is not null, 'inside 24 hours it can');
  perform pg_temp.ok((select s.work_date = d1 and s.status = 'closed' from public.attendance_sessions s where s.check_in_event_id = c_in), 'the session keeps its work day');

  -- ---------------------------------------------------------------- a check-in that waits for its check-out keeps its review flag
  r := pg_temp.add(v_admin, d, 'check_in', (wd[4] + time '08:30') at time zone v_tz); d_in := (r ->> 'event_id')::uuid;
  perform pg_temp.ok((select e.needs_review from public.attendance_events e where e.id = d_in), 'the waiting check-in is flagged');
  r := pg_temp.edit(v_admin, d_in, (wd[4] + time '08:10') at time zone v_tz);
  perform pg_temp.ok((select e.needs_review and (e.metadata ->> 'missed_checkout')::boolean from public.attendance_events e where e.id = d_in)
                     and (select s.status = 'missed_checkout' and s.check_out_event_id is null from public.attendance_sessions s where s.check_in_event_id = d_in),
                     'editing its time does not clear the flag or close the session');

  -- ---------------------------------------------------------------- nothing else moved
  perform pg_temp.ok((select e.occurred_at = (wd[2] + time '10:00') at time zone v_tz from public.attendance_events e where e.id = ev_other), 'the other company''s movement is as it was');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'attendance.edit_time') = 8,
                     'one audit row per accepted edit (a: 3, b: 2, c: 2, d: 1) and none for the refused ones',
                     (select count(*)::text from public.audit_log where action = 'attendance.edit_time'));

  -- ---------------------------------------------------------------- the owner only: a limited level (phase 26) is refused
  if to_regclass('private.admin_role_rpcs') is not null then
    update public.company_members set role = 'hr_admin' where user_id = c;
    get diagnostics n = row_count;
    perform pg_temp.ok(n = 1, 'test setup: an employee became an hr_admin');
    s := pg_temp.edit_err(c, a_in, (wd[1] + time '08:12') at time zone v_tz);
    perform pg_temp.ok(s = 'forbidden', 'an hr_admin cannot edit a movement (owner only until a row is added for him)', s);
    update public.company_members set role = 'employee' where user_id = c;
  end if;

  insert into t_res (name, ok) values ('END part 1', true);
end
$tests$;

do $report$
declare v text;
begin
  -- a block that stopped on an error must show as a failure, not as fewer passes
  insert into t_res (name, ok, detail) select 'part ' || blk.k || ' did not finish', false, 'a block stopped on an error' from generate_series(1, 1) blk(k)
  where not exists (select 1 from t_res where t_res.name = 'END part ' || blk.k);
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
