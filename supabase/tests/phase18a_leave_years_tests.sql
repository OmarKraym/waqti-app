-- Phase 18a: annual leave earned day by day, a balance per year, carry-over up to a maximum, admin edits per year,
-- asking for more with a reason, and HR setting the days taken from the balance.
-- Runs inside one transaction and always ends with an exception, so nothing is kept.
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
create function pg_temp.err_as(u uuid, q text) returns text language plpgsql as $$
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q;
  reset role;
  return '';
exception when others then
  reset role;
  return sqlerrm;
end $$;
create function pg_temp.run_as(u uuid, q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.as_user(u);
  set local role authenticated;
  execute q into r;
  reset role;
  return r;
end $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; r jsonb; v_req uuid; v_today date; y int; d date; s text; n numeric;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone 'Africa/Tripoli')::date;
  y := extract(year from v_today)::int;
  update public.companies set created_at = make_date(y, 1, 10)::timestamp at time zone 'Africa/Tripoli' where id = v_comp;
  update public.employees set hire_date = make_date(y - 5, 3, 1), manager_id = null, birth_date = '1990-01-01' where id in (a, b);
  delete from public.employee_leave_entitlements where employee_id in (a, b);
  insert into public.leave_policy (company_id, age_threshold, days_below, days_at_or_above) values (v_comp, 50, 30, 45)
  on conflict (company_id) do update set age_threshold = 50, days_below = 30, days_at_or_above = 45;
  delete from public.requests where employee_id in (a, b);

  -- ---------------------------------------------------------------- earning day by day (2025: 365 days)
  perform pg_temp.ok(private.annual_earned(30, 2025, null, '2025-01-31') = 2.5, 'January earns 2.5 of 30 days');
  perform pg_temp.ok(private.annual_earned(30, 2025, null, '2025-03-15') = 6, 'mid-March: 6 (rounded down to half a day)');
  perform pg_temp.ok(private.annual_earned(30, 2025, null, '2025-12-31') = 30, 'the whole year: 30');
  perform pg_temp.ok(private.annual_earned(30, 2025, '2025-07-01', '2025-12-31') = 15, 'hired on July 1: 15 for that year');
  perform pg_temp.ok(private.annual_earned(30, 2025, '2025-07-01', '2025-05-01') = 0, 'nothing before the hire date');
  perform pg_temp.ok(private.annual_earned(30, 2024, null, '2024-12-31') = 30, 'leap year: still 30 for the whole year');

  -- ---------------------------------------------------------------- the balance now
  r := private.leave_balance(a, 'annual', y, null, make_date(y, 3, 15));
  perform pg_temp.ok((r ->> 'earned')::numeric = private.annual_earned(30, y, null, make_date(y, 3, 15))
                     and (r ->> 'entitled')::numeric = 30 and (r ->> 'carried')::numeric = 0
                     and (r ->> 'remaining')::numeric = (r ->> 'earned')::numeric, 'balance as of a day: earned so far, 30 for the year', r::text);
  r := pg_temp.run_as(a, 'select public.employee_requests_overview()');
  perform pg_temp.ok((select (x ->> 'as_of')::date = v_today and (x ->> 'earned')::numeric = private.annual_earned(30, y, null, v_today)
                      from jsonb_array_elements(r -> 'balances') x where x ->> 'leave_type' = 'annual'),
                     'the employee sees what he has earned until today', r -> 'balances' ->> 0);

  -- ---------------------------------------------------------------- carry-over
  update public.companies set annual_carryover_max = 10 where id = v_comp;
  r := pg_temp.run_as(v_admin, format('select public.admin_set_leave_year(%L, %s, 30, null, 12)', a, y - 1));
  perform pg_temp.ok((r ->> 'used')::numeric = 12 and (r ->> 'used_outside')::numeric = 12, 'admin records 12 days used last year outside the app', r::text);
  perform pg_temp.ok(private.annual_carried(a, y) = 10, 'left 18, the maximum is 10: 10 move to this year');
  update public.companies set annual_carryover_max = 20 where id = v_comp;
  perform pg_temp.ok(private.annual_carried(a, y) = 18, 'maximum 20: all 18 move');
  update public.companies set annual_carryover_max = 0 where id = v_comp;
  perform pg_temp.ok(private.annual_carried(a, y) = 0, 'maximum 0: nothing moves');
  update public.companies set annual_carryover_max = 10 where id = v_comp;
  r := private.leave_balance(a, 'annual', y, null, make_date(y, 12, 31));
  perform pg_temp.ok((r ->> 'entitled')::numeric = 40 and (r ->> 'carried')::numeric = 10, 'this year: 30 + 10 carried', r::text);
  r := pg_temp.run_as(v_admin, format('select public.admin_set_leave_year(%L, %s, null, 4, 0)', a, y));
  perform pg_temp.ok((r ->> 'carried')::numeric = 4, 'admin sets the carried days of a year by hand', r::text);
  r := pg_temp.run_as(v_admin, format('select public.admin_set_leave_year(%L, %s, 24, null, 0)', a, y));
  perform pg_temp.ok((r ->> 'carried')::numeric = 10 and (r ->> 'year_days')::numeric = 24 and (r -> 'set' ->> 'entitled')::numeric = 24,
                     'admin sets the year''s entitlement; carried is computed again', r::text);
  r := pg_temp.run_as(v_admin, format('select public.admin_set_leave_year(%L, %s, null, null, 0)', a, y));
  perform pg_temp.ok(not exists (select 1 from public.employee_leave_years where employee_id = a and year = y), 'nothing set: the year row goes away');
  r := pg_temp.run_as(v_admin, format('select public.admin_get_leave_years(%L)', a));
  perform pg_temp.ok((r ->> 'first_year')::int = y - 1 and jsonb_array_length(r -> 'years') = 2 and (r -> 'years' -> 0 ->> 'year')::int = y
                     and (r -> 'years' -> 1 -> 'set' ->> 'used_outside')::numeric = 12, 'admin sees each year, newest first', r::text);

  -- validation and access
  s := pg_temp.err_as(v_admin, format('select public.admin_set_leave_year(%L, %s, 30.3, null, 0)', a, y));
  perform pg_temp.ok(s = 'invalid_input', 'only whole or half days', s);
  s := pg_temp.err_as(v_admin, format('select public.admin_set_leave_year(%L, %s, 30, null, 0)', a, y - 6));
  perform pg_temp.ok(s = 'invalid_input', 'not before the hiring year', s);
  s := pg_temp.err_as(a, format('select public.admin_set_leave_year(%L, %s, 99, null, 0)', a, y));
  perform pg_temp.ok(s <> '', 'an employee cannot change his balance', s);
  s := pg_temp.err_as(a, 'select count(*) from public.employee_leave_years');
  perform pg_temp.ok(s like 'permission denied%', 'the table is closed to the app', s);

  -- ---------------------------------------------------------------- more than the balance: only with a reason
  update public.employee_leave_years set used_outside = 0 where employee_id = a;
  update public.companies set annual_carryover_max = 0 where id = v_comp;
  d := v_today + 14;
  while extract(year from d + 9) <> y loop d := d - 1; end loop; -- stay in this year
  insert into public.employee_leave_years (employee_id, company_id, year, entitled) values (a, v_comp, y, 2)
  on conflict (employee_id, year) do update set entitled = 2, carried = null, used_outside = 0;
  r := pg_temp.run_as(a, format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L, null, null, null, true)$q$, d, d + 6));
  perform pg_temp.ok((r ->> 'over_balance')::boolean, 'preview says: more than the balance', r::text);
  s := pg_temp.err_as(a, format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L)$q$, d, d + 6));
  perform pg_temp.ok(s = 'insufficient_balance', 'without a reason it is refused', s);
  r := pg_temp.run_as(a, format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L, null, null, 'أحتاج أسبوعًا للسفر')$q$, d, d + 6));
  v_req := (r ->> 'id')::uuid;
  perform pg_temp.ok(r ->> 'status' = 'pending', 'with a reason it is sent', r::text);

  s := pg_temp.err_as(v_admin, format('select public.admin_decide_request(%L, ''approve'', null, %s)', v_req, (r ->> 'days')::numeric + 1));
  perform pg_temp.ok(s = 'invalid_input', 'HR cannot charge more than the days asked', s);
  s := pg_temp.err_as(v_admin, format('select public.admin_decide_request(%L, ''reject'', null, 1)', v_req));
  perform pg_temp.ok(s = 'invalid_input', 'charged days only with an approval', s);
  r := pg_temp.run_as(v_admin, format('select public.admin_decide_request(%L, ''approve'', null, 1.5)', v_req));
  perform pg_temp.ok(r ->> 'status' = 'approved' and (r ->> 'charged_days')::numeric = 1.5, 'HR approves and takes 1.5 days from the balance', r::text);
  r := private.leave_balance(a, 'annual', y);
  perform pg_temp.ok((r ->> 'used')::numeric = 1.5, 'the balance counts the charged days', r::text);

  -- old calls (2 or 3 arguments) still resolve
  s := pg_temp.err_as(v_admin, format('select public.admin_decide_request(%L, ''approve'')', gen_random_uuid()));
  perform pg_temp.ok(s = 'request_not_found', 'admin_decide_request with 2 arguments still resolves', s);
exception when others then
  perform pg_temp.ok(false, 'block 1 stopped on an unexpected error', sqlerrm);
end
$tests$;

do $tests2$
declare v_admin uuid; v_comp uuid; r jsonb; b uuid; v_req uuid; v_today date; y int; d date; s text;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  v_today := (now() at time zone 'Africa/Tripoli')::date;
  y := extract(year from v_today)::int;
  -- policy with the carry-over maximum; the old 3-argument call keeps it
  perform pg_temp.run_as(v_admin, 'select to_jsonb(public.admin_set_leave_policy(50, 30, 45, 7.5))');
  perform pg_temp.ok((select annual_carryover_max from public.companies where id = v_comp) = 7.5, 'admin sets the carry-over maximum');
  perform pg_temp.run_as(v_admin, 'select to_jsonb(public.admin_set_leave_policy(50, 30, 45))');
  perform pg_temp.ok((select annual_carryover_max from public.companies where id = v_comp) = 7.5, 'the old call leaves it as it is');
  r := pg_temp.run_as(v_admin, 'select to_jsonb(p) from public.admin_get_leave_policy() p');
  perform pg_temp.ok((r ->> 'carryover_max')::numeric = 7.5 and (r ->> 'days_below')::numeric = 30, 'and reads it back', r::text);
  s := pg_temp.err_as(v_admin, 'select public.admin_set_leave_policy(50, 30, 45, 400)');
  perform pg_temp.ok(s = 'invalid_policy', 'carry-over maximum within 0..366', s);

  -- a request without a reason that is over the balance at the final approval is still refused
  select id into b from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number offset 1 limit 1;
  insert into public.employee_leave_years (employee_id, company_id, year, entitled) values (b, v_comp, y, 30)
  on conflict (employee_id, year) do update set entitled = 30;
  d := v_today + 3;
  while extract(isodow from d) in (5) loop d := d + 1; end loop;
  r := pg_temp.run_as(b, format($q$select public.employee_submit_request(gen_random_uuid(), 'leave', 'annual', %L, %L)$q$, d, d));
  v_req := (r ->> 'id')::uuid;
  update public.employee_leave_years set entitled = 0 where employee_id = b and year = y;
  s := pg_temp.err_as(v_admin, format('select public.admin_decide_request(%L, ''approve'')', v_req));
  perform pg_temp.ok(s = 'insufficient_balance', 'no reason and no balance at the final approval: refused', s);
  -- HR may approve it by charging 0 days
  r := pg_temp.run_as(v_admin, format('select public.admin_decide_request(%L, ''approve'', null, 0)', v_req));
  perform pg_temp.ok(r ->> 'status' = 'approved' and (r ->> 'charged_days')::numeric = 0, 'charging 0 days lets HR approve it', r::text);
exception when others then
  perform pg_temp.ok(false, 'block 2 stopped on an unexpected error', sqlerrm);
end
$tests2$;

do $report$
declare v text;
begin
  select format('RESULT passed=%s failed=%s%s', count(*) filter (where ok), count(*) filter (where not ok),
           coalesce(E'\n' || string_agg(format('FAIL %s: %s [%s]', n, name, left(coalesce(detail, ''), 300)), E'\n') filter (where not ok), ''))
    into v from t_res;
  raise exception '%', v;
end
$report$;
