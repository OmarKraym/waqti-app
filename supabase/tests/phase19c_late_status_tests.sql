-- Phase 19c: what the employee sees after a check-in (employee_late_status) and a race-proof monthly limit on pending permission requests.
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
create function pg_temp.errstate(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlstate; end $$;
-- the status as the employee sees it (jwt of that employee, role authenticated), then back to the test's own role
create function pg_temp.st(u uuid, ev uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.employee_late_status(ev);
  reset role;
  return r;
end $$;
-- a late-arrival style request of one employee on one day: starts at the shift start (08:00), ends at the arrival time given
create function pg_temp.req(p_emp uuid, p_type uuid, p_status text, p_day date, p_end time default '08:30') returns uuid language sql as $$
  insert into public.requests (employee_id, request_type, status, start_at, end_at, company_id, permission_type_id, minutes)
  select p_emp, 'permission', p_status::public.request_status, (p_day + time '08:00') at time zone c.timezone,
         (p_day + p_end) at time zone c.timezone, e.company_id, p_type, 30
  from public.employees e join public.companies c on c.id = e.company_id where e.id = p_emp
  returning id $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; v_today date; mstart date; doff date; wd date[];
  t_late uuid; t2 uuid; t_g uuid; t_gn uuid; t_g2 uuid;
  e15 uuid; e16 uuid; e_2nd uuid; e_out uuid; e_70 uuid; e_pers uuid; e_offl uuid; e_early uuid; e30 uuid; e_sec uuid;
  e_off uuid; e_today uuid; e_b uuid;
  r jsonb; r2 jsonb; s text; ev uuid; k int;
  tiers jsonb := '{"tiers":[{"from":1,"to":15,"deduct":0},{"from":16,"to":30,"deduct":30},{"from":31,"to":null,"deduct":60}]}';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id <> v_admin and e.id <> a and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone v_tz)::date;
  mstart := (date_trunc('month', v_today) - interval '1 month')::date;          -- all the test days are inside last month
  doff := mstart + 1;                                                              -- the weekday of `doff` is the day off
  if extract(dow from doff) = extract(dow from v_today) then doff := doff + 1; end if;
  select array_agg(d order by d) into wd from (
    select g::date d from generate_series(mstart + 2, mstart + 27, interval '1 day') g
    where extract(dow from g) <> extract(dow from doff) order by g limit 14) x;

  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, g <> extract(dow from doff)::int, case when g <> extract(dow from doff)::int then time '08:00' end,
         case when g <> extract(dow from doff)::int then time '16:00' end, v_comp
  from generate_series(0, 6) g;
  update public.companies set late_grace_min = 15, early_grace_min = 10, late_rule = 'all_after_grace' where id = v_comp;
  update public.employees set late_grace_min = null where id = a;
  select id into t_late from public.permission_types where company_id = v_comp and mode = 'late_arrival' order by sort_order limit 1;
  update public.permission_types set max_per_month = 3, max_minutes = 60, days_back = 60, days_ahead = 0, is_active = true, sort_order = 3 where id = t_late;

  -- events of employee a (shift 08:00-16:00, grace 15)
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[1] + time '08:15') at time zone v_tz, true, 'password', 'none') returning id into e15;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[1] + time '13:00') at time zone v_tz, true, 'password', 'none') returning id into e_2nd;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_out', (wd[1] + time '15:50') at time zone v_tz, true, 'password', 'none') returning id into e_out;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[2] + time '08:16') at time zone v_tz, true, 'password', 'none') returning id into e16;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[3] + time '09:10') at time zone v_tz, true, 'password', 'none') returning id into e_70;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[4] + time '08:20') at time zone v_tz, true, 'password', 'none') returning id into e_pers;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy, metadata, created_at)
  values (a, 'check_in', (wd[5] + time '08:16') at time zone v_tz, true, 'password', 'none',
          '{"offline":true,"source":"offline_sync","sync_delay_s":18000}', (wd[5] + time '13:16') at time zone v_tz) returning id into e_offl;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[6] + time '07:50') at time zone v_tz, true, 'password', 'none') returning id into e_early;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[7] + time '08:30') at time zone v_tz, true, 'password', 'none') returning id into e30;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (wd[8] + time '08:15:30') at time zone v_tz, true, 'password', 'none') returning id into e_sec;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (doff + time '09:30') at time zone v_tz, true, 'password', 'none') returning id into e_off;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (a, 'check_in', (v_today + time '08:16') at time zone v_tz, true, 'password', 'none') returning id into e_today;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy)
  values (b, 'check_in', (wd[1] + time '08:30') at time zone v_tz, true, 'password', 'none') returning id into e_b;

  perform pg_temp.ok(a is not null and b is not null and a <> b and t_late is not null, 'setup: two employees and a late-arrival type');

  -- ---------------------------------------------------------------- the reasons (rule all_after_grace, grace 15, limit 3, no policy)
  r := pg_temp.st(a, e15);
  perform pg_temp.ok(r ->> 'reason' = 'within_grace' and not (r ->> 'offer')::boolean and (r ->> 'late_min')::int = 15 and (r ->> 'grace_min')::int = 15
    and (r ->> 'chargeable_min')::int = 0 and r ->> 'rule' = 'all_after_grace' and r ->> 'event_id' = e15::text, '08:15 with grace 15 is within_grace, no offer', r::text);
  perform pg_temp.ok(r -> 'deduction_min' = 'null'::jsonb, 'no policy: deduction_min is null', r::text);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'offer')::boolean and (r ->> 'late_min')::int = 16 and (r ->> 'chargeable_min')::int = 16
    and (r ->> 'remaining')::int = 3 and r -> 'deduction_min' = 'null'::jsonb, '08:16: offer, 16 late, 16 chargeable, 3 left', r::text);
  perform pg_temp.ok(r -> 'permission' ->> 'id' = t_late::text and (r -> 'permission' ->> 'max_per_month')::int = 3 and (r -> 'permission' ->> 'used')::int = 0
    and (r -> 'permission' ->> 'pending')::int = 0 and r -> 'permission' ->> 'month' = to_char(wd[2], 'YYYY-MM'), 'the answer carries the permission usage of that month', r::text);
  r := pg_temp.st(a, e_sec);
  perform pg_temp.ok((r ->> 'late_min')::int = 16 and r ->> 'reason' = 'offer', '08:15:30 counts as 16 minutes (rounded up like the attendance list)', r::text);
  r := pg_temp.st(a, e30);
  perform pg_temp.ok((r ->> 'late_min')::int = 30 and (r ->> 'chargeable_min')::int = 30 and r ->> 'reason' = 'offer', '08:30: 30 late', r::text);
  r := pg_temp.st(a, e_early);
  perform pg_temp.ok(r ->> 'reason' = 'not_late' and (r ->> 'late_min')::int = 0 and (r ->> 'chargeable_min')::int = 0 and not (r ->> 'offer')::boolean, 'before the shift start: not_late', r::text);
  r := pg_temp.st(a, e_2nd);
  perform pg_temp.ok(r ->> 'reason' = 'not_first' and not (r ->> 'offer')::boolean and (r ->> 'late_min')::int = 0, 'a second check-in of the day: not_first', r::text);
  r := pg_temp.st(a, e_out);
  perform pg_temp.ok(r ->> 'reason' = 'not_check_in' and not (r ->> 'offer')::boolean, 'a check-out: not_check_in', r::text);
  r := pg_temp.st(a, e_off);
  perform pg_temp.ok(r ->> 'reason' = 'day_off' and not (r ->> 'offer')::boolean and (r ->> 'late_min')::int = 0, 'a check-in on the day off: day_off', r::text);
  perform pg_temp.ok(r -> 'remaining' = 'null'::jsonb and r -> 'permission' = 'null'::jsonb and r -> 'deduction_min' = 'null'::jsonb, 'when nothing applies there is no permission, balance or deduction', r::text);

  -- an offline-synced check-in (arrived hours later) gets the same answer as an online one
  r := pg_temp.st(a, e16);
  r2 := pg_temp.st(a, e_offl);
  perform pg_temp.ok((r - 'event_id') = (r2 - 'event_id') and r2 ->> 'event_id' = e_offl::text, 'offline-synced check-in: same answer as online', r2::text);

  -- the same minutes as the attendance list (private.punch_lateness), under both rules
  for k in 1..2 loop
    update public.companies set late_rule = case k when 1 then 'all_after_grace' else 'beyond_grace' end where id = v_comp;
    foreach ev in array array[e15, e16, e30, e_sec, e_pers] loop
      r := pg_temp.st(a, ev);
      perform pg_temp.ok((r ->> 'chargeable_min')::int = (select private.punch_lateness(a, x.id, 'check_in', x.occurred_at) from public.attendance_events x where x.id = ev),
        format('chargeable_min equals punch_lateness (%s, rule %s)', to_char((select occurred_at at time zone v_tz from public.attendance_events where id = ev), 'DD HH24:MI:SS'), k), r::text);
    end loop;
  end loop;
  update public.companies set late_rule = 'beyond_grace' where id = v_comp;
  r := pg_temp.st(a, e15);
  perform pg_temp.ok(r ->> 'reason' = 'within_grace' and (r ->> 'chargeable_min')::int = 0 and r ->> 'rule' = 'beyond_grace', 'beyond_grace: 08:15 is within_grace', r::text);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'late_min')::int = 16 and (r ->> 'chargeable_min')::int = 1 and r ->> 'rule' = 'beyond_grace', 'beyond_grace: 08:16 is 16 late but only 1 chargeable', r::text);
  r := pg_temp.st(a, e30);
  perform pg_temp.ok((r ->> 'chargeable_min')::int = 15, 'beyond_grace: 08:30 charges 15', r::text);
  update public.companies set late_rule = 'all_after_grace' where id = v_comp;

  -- a personal grace
  update public.employees set late_grace_min = 30 where id = a;
  r := pg_temp.st(a, e_pers);
  perform pg_temp.ok(r ->> 'reason' = 'within_grace' and (r ->> 'grace_min')::int = 30 and (r ->> 'late_min')::int = 20 and (r ->> 'chargeable_min')::int = 0, 'personal grace 30: 08:20 is within_grace', r::text);
  r := pg_temp.st(a, e30);
  perform pg_temp.ok(r ->> 'reason' = 'within_grace', 'personal grace 30: 08:30 is still within_grace', r::text);
  update public.employees set late_grace_min = null where id = a;
  r := pg_temp.st(a, e_pers);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'grace_min')::int = 15 and (r ->> 'chargeable_min')::int = 20, 'no personal grace: the company grace (15) applies', r::text);

  -- ---------------------------------------------------------------- the monthly balance
  perform pg_temp.req(a, t_late, 'approved', wd[10]);
  perform pg_temp.req(a, t_late, 'pending', wd[11]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'remaining')::int = 1 and (r -> 'permission' ->> 'used')::int = 1 and (r -> 'permission' ->> 'pending')::int = 1,
    'used 1 + pending 1: 1 left, still an offer', r::text);
  perform pg_temp.req(a, t_late, 'pending', wd[12]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'no_balance' and not (r ->> 'offer')::boolean and (r ->> 'remaining')::int = 0 and r -> 'permission' is not null, 'used + pending = 3: no_balance, 0 left', r::text);
  update public.permission_types set max_per_month = null where id = t_late;
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'offer')::boolean and r -> 'remaining' = 'null'::jsonb, 'no monthly limit: remaining is null, still an offer', r::text);
  update public.permission_types set max_per_month = 3 where id = t_late;
  delete from public.requests where employee_id = a;
  -- requests of other months do not count
  perform pg_temp.req(a, t_late, 'approved', mstart - 5);
  perform pg_temp.req(a, t_late, 'approved', (mstart + interval '1 month')::date + 3);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok((r ->> 'remaining')::int = 3 and (r -> 'permission' ->> 'used')::int = 0, 'requests of the months before and after do not count', r::text);
  delete from public.requests where employee_id = a;
  -- a rejected or cancelled request does not count
  perform pg_temp.req(a, t_late, 'rejected', wd[10]);
  perform pg_temp.req(a, t_late, 'cancelled', wd[11]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok((r ->> 'remaining')::int = 3, 'rejected and cancelled requests do not use the balance', r::text);
  delete from public.requests where employee_id = a;

  -- already: a pending or approved justification for that day
  perform pg_temp.req(a, t_late, 'pending', wd[2]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'already' and not (r ->> 'offer')::boolean and (r ->> 'late_min')::int = 16, 'a pending justification for that day: already', r::text);
  delete from public.requests where employee_id = a;
  perform pg_temp.req(a, t_late, 'approved', wd[2]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'already' and not (r ->> 'offer')::boolean, 'an approved justification for that day: already', r::text);
  delete from public.requests where employee_id = a;
  perform pg_temp.req(a, t_late, 'rejected', wd[2]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'remaining')::int = 3, 'a rejected one for that day: offer again', r::text);
  delete from public.requests where employee_id = a;
  perform pg_temp.req(a, t_late, 'approved', wd[10]);
  perform pg_temp.req(a, t_late, 'approved', wd[11]);
  perform pg_temp.req(a, t_late, 'pending', wd[2]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'already' and (r ->> 'remaining')::int = 0, 'already wins over no_balance (the pending one is of that day)', r::text);
  delete from public.requests where employee_id = a;
  -- somebody else's justification for the same day does not matter
  perform pg_temp.req(b, t_late, 'approved', wd[2]);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'offer', 'another employee''s justification does not matter', r::text);
  delete from public.requests where employee_id = b;

  -- too long: 09:10 is 70 minutes after the shift start, the type allows 60
  r := pg_temp.st(a, e_70);
  perform pg_temp.ok(r ->> 'reason' = 'too_long' and not (r ->> 'offer')::boolean and (r ->> 'late_min')::int = 70 and (r ->> 'chargeable_min')::int = 70, '70 late with max_minutes 60: too_long', r::text);
  update public.permission_types set max_minutes = 70 where id = t_late;
  r := pg_temp.st(a, e_70);
  perform pg_temp.ok(r ->> 'reason' = 'offer', 'max_minutes 70: exactly 70 is allowed', r::text);
  update public.permission_types set max_minutes = 69 where id = t_late;
  r := pg_temp.st(a, e_70);
  perform pg_temp.ok(r ->> 'reason' = 'too_long', 'max_minutes 69: too_long', r::text);
  update public.permission_types set max_minutes = null where id = t_late;
  r := pg_temp.st(a, e_70);
  perform pg_temp.ok(r ->> 'reason' = 'offer', 'no max_minutes: offer', r::text);
  update public.permission_types set max_minutes = 60 where id = t_late;

  -- the type
  update public.permission_types set is_active = false where id = t_late;
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'no_type' and not (r ->> 'offer')::boolean and r -> 'permission' = 'null'::jsonb and r -> 'remaining' = 'null'::jsonb
    and (r ->> 'chargeable_min')::int = 16, 'no active late-arrival type: no_type', r::text);
  update public.permission_types set is_active = true where id = t_late;
  insert into public.permission_types (company_id, name, mode, max_per_month, max_minutes, days_back, days_ahead, is_active, sort_order)
  values (v_comp, 'تبرير ثانٍ', 'late_arrival', 5, 60, 60, 0, true, 1) returning id into t2;
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r -> 'permission' ->> 'id' = t2::text and (r ->> 'remaining')::int = 5, 'two active types: the first by sort order is used', r::text);
  update public.permission_types set is_active = false where id = t2;
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r -> 'permission' ->> 'id' = t_late::text, 'the inactive one is skipped', r::text);

  -- the window of the type (days_back / days_ahead)
  update public.permission_types set days_back = 0 where id = t_late;
  r := pg_temp.st(a, e16);
  perform pg_temp.ok(r ->> 'reason' = 'outside_window' and not (r ->> 'offer')::boolean, 'an old day with days_back 0: outside_window', r::text);
  r := pg_temp.st(a, e_today);
  perform pg_temp.ok(r ->> 'reason' = 'offer' and (r ->> 'offer')::boolean, 'today with days_back 0: offer', r::text);
  update public.permission_types set days_back = 60 where id = t_late;

  -- ---------------------------------------------------------------- the expected deduction
  insert into public.deduction_policies (company_id, effective_from, kind, params) values (v_comp, v_today - 400, 'tiers', tiers);
  r := pg_temp.st(a, e16);
  perform pg_temp.ok((r ->> 'deduction_min')::int = 30 and (r ->> 'deduction_min')::int = private.late_deduction(v_comp, wd[2], 16), 'with a policy: 16 chargeable -> 30 (same as late_deduction)', r::text);
  r := pg_temp.st(a, e_70);
  perform pg_temp.ok((r ->> 'deduction_min')::int = 60 and (r ->> 'deduction_min')::int = private.late_deduction(v_comp, wd[3], 70), 'with a policy: 70 chargeable -> 60', r::text);
  r := pg_temp.st(a, e15);
  perform pg_temp.ok((r ->> 'deduction_min')::int = 0 and r ->> 'reason' = 'within_grace', 'within_grace with a policy: deduction_min 0', r::text);
  r := pg_temp.st(a, e_early);
  perform pg_temp.ok((r ->> 'deduction_min')::int = 0, 'not_late with a policy: deduction_min 0', r::text);
  foreach ev in array array[e_2nd, e_out, e_off] loop
    perform pg_temp.ok(pg_temp.st(a, ev) -> 'deduction_min' = 'null'::jsonb, 'not applicable (not_first / not_check_in / day_off): no deduction value');
  end loop;
  update public.companies set late_rule = 'beyond_grace' where id = v_comp;
  r := pg_temp.st(a, e16);
  perform pg_temp.ok((r ->> 'chargeable_min')::int = 1 and (r ->> 'deduction_min')::int = 0, 'beyond_grace: 1 chargeable minute falls in the free tier -> 0', r::text);
  r := pg_temp.st(a, e30);
  perform pg_temp.ok((r ->> 'chargeable_min')::int = 15 and (r ->> 'deduction_min')::int = 0, 'beyond_grace: 15 chargeable -> 0', r::text);
  r := pg_temp.st(a, e_70);
  perform pg_temp.ok((r ->> 'chargeable_min')::int = 55 and (r ->> 'deduction_min')::int = 60, 'beyond_grace: 70 late -> 55 chargeable -> 60', r::text);
  update public.companies set late_rule = 'all_after_grace' where id = v_comp;
  -- a policy that starts after the day does not apply to it
  delete from public.deduction_policies where company_id = v_comp;
  insert into public.deduction_policies (company_id, effective_from, kind, params) values (v_comp, wd[3] + 1, 'tiers', tiers);
  perform pg_temp.ok(pg_temp.st(a, e_70) -> 'deduction_min' = 'null'::jsonb and pg_temp.st(a, e16) -> 'deduction_min' = 'null'::jsonb, 'a policy that starts after the day does not apply (null)');
  delete from public.deduction_policies where company_id = v_comp;

  -- ---------------------------------------------------------------- who may ask
  s := pg_temp.err(format('select pg_temp.st(%L, %L)', a, e_b));
  perform pg_temp.ok(s = 'event_not_found', 'another employee''s event: event_not_found', s);
  s := pg_temp.err(format('select pg_temp.st(%L, %L)', a, gen_random_uuid()));
  perform pg_temp.ok(s = 'event_not_found', 'an unknown id: event_not_found', s);
  s := pg_temp.err(format('select pg_temp.st(%L, null)', a));
  perform pg_temp.ok(s = 'event_not_found', 'a null id: event_not_found', s);
  s := pg_temp.err(format('select pg_temp.st(%L, %L)', v_admin, e16));
  perform pg_temp.ok(s = 'event_not_found', 'even a company admin sees only his own events', s);
  s := pg_temp.err(format('select pg_temp.st(null, %L)', e16));
  perform pg_temp.ok(s = 'not_authenticated', 'nobody signed in: not_authenticated', s);
  r := pg_temp.st(b, e_b);
  perform pg_temp.ok(r ->> 'event_id' = e_b::text, 'the owner of the event gets an answer', r::text);
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.employee_late_status(uuid)', 'execute')
                 and not has_function_privilege('anon', 'public.employee_late_status(uuid)', 'execute'), 'employee_late_status: authenticated only');
  perform pg_temp.ok((select p.provolatile from pg_proc p where p.oid = 'public.employee_late_status(uuid)'::regprocedure) = 's', 'employee_late_status only reads (stable)');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.requests_limit_guard()', 'execute')
                 and not has_function_privilege('anon', 'private.requests_limit_guard()', 'execute'), 'the guard function is not callable by users');
  perform pg_temp.ok(exists (select 1 from pg_trigger t where t.tgrelid = 'public.requests'::regclass and t.tgname = 'requests_limit_guard' and not t.tgisinternal and t.tgenabled = 'O'),
    'the guard trigger exists and is enabled');

  -- ---------------------------------------------------------------- the guard: a direct insert cannot break the monthly limit
  insert into public.permission_types (company_id, name, mode, max_per_month, max_minutes, days_back, days_ahead, is_active, sort_order)
  values (v_comp, 'حارس الحد', 'range', 1, null, 60, 30, true, 90) returning id into t_g;
  insert into public.permission_types (company_id, name, mode, max_per_month, max_minutes, days_back, days_ahead, is_active, sort_order)
  values (v_comp, 'حارس بلا حد', 'range', null, null, 60, 30, true, 91) returning id into t_gn;
  delete from public.requests where employee_id in (a, b);
  perform pg_temp.req(a, t_g, 'pending', wd[1]);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and permission_type_id = t_g) = 1, 'guard: the first pending request is accepted');
  s := pg_temp.err(format('select pg_temp.req(%L, %L, ''pending'', %L)', a, t_g, wd[3]));
  perform pg_temp.ok(s = 'permission_limit', 'guard: a second pending request in the month is refused', s);
  s := pg_temp.errstate(format('select pg_temp.req(%L, %L, ''pending'', %L)', a, t_g, wd[3]));
  perform pg_temp.ok(s = 'P0001', 'guard: with the same error code as the function (P0001)', s);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and permission_type_id = t_g) = 1, 'guard: the refused insert left nothing behind');
  perform pg_temp.req(a, t_g, 'approved', wd[4]);
  perform pg_temp.req(a, t_g, 'rejected', wd[5]);
  perform pg_temp.req(a, t_g, 'cancelled', wd[6]);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and permission_type_id = t_g) = 4, 'guard: approved, rejected and cancelled rows are not blocked');
  s := pg_temp.err(format('select pg_temp.req(%L, %L, ''pending'', %L)', a, t_g, wd[7]));
  perform pg_temp.ok(s = 'permission_limit', 'guard: used + pending still count after more rows', s);
  perform pg_temp.req(a, t_g, 'pending', mstart - 3);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and permission_type_id = t_g and status = 'pending') = 2, 'guard: another month has its own count');
  perform pg_temp.req(b, t_g, 'pending', wd[1]);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = b and permission_type_id = t_g) = 1, 'guard: another employee has his own count');
  perform pg_temp.req(a, t_gn, 'pending', wd[1]);
  perform pg_temp.req(a, t_gn, 'pending', wd[3]);
  perform pg_temp.req(a, t_gn, 'pending', wd[7]);
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and permission_type_id = t_gn) = 3, 'guard: a type without a monthly limit is never refused');
  -- a leave request is not touched
  insert into public.requests (employee_id, request_type, leave_type, status, start_at, end_at, company_id, days)
  values (a, 'leave', 'annual', 'pending', (v_today + 20) at time zone v_tz, (v_today + 21) at time zone v_tz, v_comp, 1);
  perform pg_temp.ok(exists (select 1 from public.requests where employee_id = a and request_type = 'leave' and start_at = (v_today + 20) at time zone v_tz), 'guard: leave requests are not affected');

  -- the real path still works with the guard in place: one accepted, the next one refused by the limit
  delete from public.requests where employee_id = a;
  insert into public.permission_types (company_id, name, mode, max_per_month, max_minutes, days_back, days_ahead, is_active, sort_order)
  values (v_comp, 'حارس عبر الدالة', 'range', 1, 240, 7, 7, true, 92) returning id into t_g2;
  perform pg_temp.as_user(a);
  set local role authenticated;
  r := public.employee_submit_request(gen_random_uuid(), 'permission', null, null, null, (v_today + time '10:00') at time zone v_tz, (v_today + time '11:00') at time zone v_tz, null, false, t_g2);
  perform pg_temp.ok(r ->> 'status' = 'pending' and r ->> 'permission_type_id' = t_g2::text, 'through employee_submit_request: the first request is accepted', r::text);
  s := pg_temp.err(format('select public.employee_submit_request(gen_random_uuid(), ''permission'', null, null, null, %L, %L, null, false, %L)',
                          (v_today + time '12:00') at time zone v_tz, (v_today + time '13:00') at time zone v_tz, t_g2));
  perform pg_temp.ok(s = 'permission_limit', 'through employee_submit_request: the second one is refused (permission_limit)', s);
  reset role;
  perform pg_temp.ok((select count(*) from public.requests where employee_id = a and permission_type_id = t_g2) = 1, 'through employee_submit_request: exactly one request was saved');
  perform pg_temp.ok(true, 'END part 1');
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
