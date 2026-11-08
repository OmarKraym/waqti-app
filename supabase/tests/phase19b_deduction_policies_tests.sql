-- Phase 19b: late deduction policies (proportional or tiers), one calculation function, dated policies per company.
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
  v_admin uuid; a uuid; v_comp uuid; v_tz text; v_today date;
  v_other uuid; v_none uuid; p1 uuid; p2 uuid; pb uuid; v_new uuid; v_new2 uuid;
  r jsonb; s text; rec record; i int; n0 int; v_prev int;
  mins int[] := array[1, 7, 8, 15, 16, 30, 31];
  e_up int[] := array[5, 5, 10, 10, 15, 20, 25];
  e_down int[] := array[0, 0, 5, 10, 10, 20, 20];
  e_near int[] := array[0, 5, 5, 10, 10, 20, 20];
  tmins int[] := array[0, 1, 15, 16, 30, 31, 600];
  e_tier int[] := array[0, 0, 0, 30, 30, 60, 60];
  tiers jsonb := '{"tiers":[{"from":1,"to":15,"deduct":0},{"from":16,"to":30,"deduct":30},{"from":31,"to":null,"deduct":60}]}';
  one2one jsonb := '{"per_minutes":1,"deduct_minutes":1,"round_to":1,"rounding":"nearest"}';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  v_today := (now() at time zone v_tz)::date;
  insert into public.companies (name) values ('شركة أخرى') returning id into v_other;
  insert into public.companies (name) values ('شركة بلا سياسة') returning id into v_none;

  -- ---------------------------------------------------------------- the calculation
  for i in 1..7 loop
    perform pg_temp.ok(private.deduction_calc('proportional', jsonb_build_object('per_minutes', 15, 'deduct_minutes', 10, 'round_to', 5, 'rounding', 'up'), mins[i]) = e_up[i], format('proportional 15:10 step 5 up: %s late -> %s', mins[i], e_up[i]));
    perform pg_temp.ok(private.deduction_calc('proportional', jsonb_build_object('per_minutes', 15, 'deduct_minutes', 10, 'round_to', 5, 'rounding', 'down'), mins[i]) = e_down[i], format('proportional 15:10 step 5 down: %s late -> %s', mins[i], e_down[i]));
    perform pg_temp.ok(private.deduction_calc('proportional', jsonb_build_object('per_minutes', 15, 'deduct_minutes', 10, 'round_to', 5, 'rounding', 'nearest'), mins[i]) = e_near[i], format('proportional 15:10 step 5 nearest: %s late -> %s', mins[i], e_near[i]));
  end loop;
  perform pg_temp.ok(private.deduction_calc('proportional', one2one, 1) = 1 and private.deduction_calc('proportional', one2one, 7) = 7 and private.deduction_calc('proportional', one2one, 100) = 100, 'proportional 1:1 step 1 returns the late minutes');
  perform pg_temp.ok(private.deduction_calc('proportional', '{"per_minutes":15,"deduct_minutes":0,"round_to":5,"rounding":"up"}', 40) = 0, 'deduct_minutes 0 deducts nothing');
  for i in 1..7 loop
    perform pg_temp.ok(private.deduction_calc('tiers', tiers, tmins[i]) = e_tier[i], format('tiers: %s late -> %s', tmins[i], e_tier[i]));
  end loop;
  perform pg_temp.ok(private.deduction_calc('tiers', '{"tiers":[{"from":10,"to":20,"deduct":5}]}', 9) = 0 and private.deduction_calc('tiers', '{"tiers":[{"from":10,"to":20,"deduct":5}]}', 10) = 5
    and private.deduction_calc('tiers', '{"tiers":[{"from":10,"to":20,"deduct":5}]}', 21) = 0, 'tiers: below the first tier and above the last closed tier is 0');
  perform pg_temp.ok(private.deduction_calc('tiers', tiers, null) = 0 and private.deduction_calc('proportional', one2one, null) = 0 and private.deduction_calc('proportional', one2one, -5) = 0, 'null and negative chargeable minutes deduct 0');

  -- ---------------------------------------------------------------- what is a valid policy
  perform pg_temp.ok(private.deduction_params_ok('tiers', tiers), 'valid tiers are accepted');
  perform pg_temp.ok(private.deduction_params_ok('proportional', one2one), 'valid proportional is accepted');
  perform pg_temp.ok(private.deduction_params_ok('tiers', '{"tiers":[{"from":1,"deduct":5}]}'), 'an open last tier may leave "to" out');
  for rec in select * from (values
    ('tiers', '{"tiers":[{"from":1,"to":15,"deduct":0},{"from":17,"to":30,"deduct":5}]}'),
    ('tiers', '{"tiers":[{"from":1,"to":15,"deduct":0},{"from":15,"to":30,"deduct":5}]}'),
    ('tiers', '{"tiers":[{"from":10,"to":5,"deduct":0}]}'),
    ('tiers', '{"tiers":[{"from":1.5,"to":15,"deduct":0}]}'),
    ('tiers', '{"tiers":[{"from":1,"to":15,"deduct":"a"}]}'),
    ('tiers', '{"tiers":[{"from":1,"to":15,"deduct":-1}]}'),
    ('tiers', '{"tiers":[{"from":1,"to":null,"deduct":0},{"from":16,"to":30,"deduct":5}]}'),
    ('tiers', '{"tiers":[]}'),
    ('tiers', '{"tiers":[{"from":0,"to":15,"deduct":0}]}'),
    ('tiers', '{"tiers":[{"from":1,"to":15,"deduct":1441}]}'),
    ('tiers', '[]'),
    ('proportional', '{"per_minutes":15,"deduct_minutes":10,"round_to":7,"rounding":"up"}'),
    ('proportional', '{"per_minutes":0,"deduct_minutes":10,"round_to":5,"rounding":"up"}'),
    ('proportional', '{"per_minutes":241,"deduct_minutes":10,"round_to":5,"rounding":"up"}'),
    ('proportional', '{"per_minutes":15,"deduct_minutes":-1,"round_to":5,"rounding":"up"}'),
    ('proportional', '{"per_minutes":15,"deduct_minutes":10,"round_to":5,"rounding":"x"}'),
    ('proportional', '{"per_minutes":15,"deduct_minutes":10,"round_to":5}'),
    ('proportional', '{"per_minutes":"15","deduct_minutes":10,"round_to":5,"rounding":"up"}'),
    ('weird', '{"per_minutes":15,"deduct_minutes":10,"round_to":5,"rounding":"up"}')
  ) v(k, p) loop
    perform pg_temp.ok(not private.deduction_params_ok(rec.k, rec.p::jsonb), 'rejected: ' || rec.k || ' ' || left(rec.p, 70));
  end loop;

  -- ---------------------------------------------------------------- which policy applies on a day
  insert into public.deduction_policies (company_id, effective_from, kind, params) values (v_comp, v_today - 10, 'proportional', one2one) returning id into p1;
  insert into public.deduction_policies (company_id, effective_from, kind, params) values (v_comp, v_today + 5, 'tiers', tiers) returning id into p2;
  insert into public.deduction_policies (company_id, effective_from, kind, params) values (v_other, v_today - 20, 'tiers', '{"tiers":[{"from":1,"to":null,"deduct":99}]}') returning id into pb;
  perform pg_temp.ok(private.late_deduction(v_comp, v_today - 3, 20) = 20, 'a day inside the first policy uses it (20)');
  perform pg_temp.ok(private.late_deduction(v_comp, v_today + 4, 20) = 20, 'the day before the second policy still uses the first');
  perform pg_temp.ok(private.late_deduction(v_comp, v_today + 5, 20) = 30, 'from its date the second policy applies (tiers: 20 -> 30)');
  perform pg_temp.ok(private.late_deduction(v_comp, v_today - 11, 20) = 0, 'a day before the first policy has no deduction');
  perform pg_temp.ok(private.late_deduction(v_comp, v_today - 15, 20) = 0, 'another company''s policy never applies here');
  perform pg_temp.ok(private.late_deduction(v_other, v_today, 20) = 99, 'the other company uses its own policy');
  perform pg_temp.ok(private.late_deduction(v_none, v_today, 20) = 0, 'a company without a policy deducts 0');
  perform pg_temp.ok(private.late_deduction(v_comp, v_today, 0) = 0 and private.late_deduction(v_comp, v_today, null) = 0, 'no chargeable minutes, no deduction');

  -- ---------------------------------------------------------------- admin
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_list_deduction_policies();
  perform pg_temp.ok(jsonb_array_length(r) = 2, 'the list has this company''s 2 policies only', r::text);
  perform pg_temp.ok((select (x ->> 'editable')::boolean from jsonb_array_elements(r) x where x ->> 'id' = p1::text) = false, 'a past policy is not editable');
  perform pg_temp.ok((select (x ->> 'editable')::boolean from jsonb_array_elements(r) x where x ->> 'id' = p2::text) = true, 'a future policy is editable');
  perform pg_temp.ok((r -> 0 ->> 'id') = p2::text, 'newest first');

  r := public.admin_save_deduction_policy(null, v_today + 10, 'proportional', '{"per_minutes":15,"deduct_minutes":10,"round_to":5,"rounding":"nearest","junk":1}');
  v_new := (r ->> 'id')::uuid;
  perform pg_temp.ok(r ->> 'kind' = 'proportional' and (r ->> 'editable')::boolean and r -> 'params' ? 'junk' = false and (select count(*) from jsonb_object_keys(r -> 'params')) = 4,
    'a new policy is saved with exactly its four fields (unknown keys dropped)', r::text);
  r := public.admin_save_deduction_policy(null, v_today + 11, 'tiers', '{"tiers":[{"from":1,"to":15,"deduct":0,"junk":2},{"from":16,"deduct":30}]}');
  v_new2 := (r ->> 'id')::uuid;
  perform pg_temp.ok(r::text not like '%junk%' and r -> 'params' -> 'tiers' -> 1 -> 'to' = 'null'::jsonb, 'tiers are normalised (open last tier has to = null)', r::text);

  s := pg_temp.err(format('select public.admin_save_deduction_policy(null, %L, ''tiers'', %L)', v_today - 1, tiers::text));
  perform pg_temp.ok(s = 'policy_locked', 'a new policy cannot start in the past', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(%L, %L, ''tiers'', %L)', p1, v_today + 30, tiers::text));
  perform pg_temp.ok(s = 'policy_locked', 'a past policy cannot be edited', s);
  s := pg_temp.err(format('select public.admin_delete_deduction_policy(%L)', p1));
  perform pg_temp.ok(s = 'policy_locked', 'a past policy cannot be deleted', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(null, %L, ''tiers'', %L)', v_today + 10, tiers::text));
  perform pg_temp.ok(s = 'policy_date_taken', 'one policy per start date', s);
  reset role;
  select count(*) into n0 from public.deduction_policies where company_id = v_comp;
  set local role authenticated;
  s := pg_temp.err(format('select public.admin_save_deduction_policy(null, %L, ''tiers'', %L)', v_today + 20, '{"tiers":[{"from":1,"to":15,"deduct":0},{"from":17,"to":30,"deduct":5}]}'));
  perform pg_temp.ok(s = 'invalid_settings', 'a tier gap is refused', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(null, %L, ''weird'', %L)', v_today + 20, tiers::text));
  perform pg_temp.ok(s = 'invalid_settings', 'an unknown kind is refused', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(null, null, ''tiers'', %L)', tiers::text));
  perform pg_temp.ok(s = 'invalid_settings', 'a missing date is refused', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(gen_random_uuid(), %L, ''tiers'', %L)', v_today + 20, tiers::text));
  perform pg_temp.ok(s = 'policy_not_found', 'editing an unknown id', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(%L, %L, ''tiers'', %L)', pb, v_today + 20, tiers::text));
  perform pg_temp.ok(s = 'policy_not_found', 'another company''s policy cannot be edited', s);
  s := pg_temp.err(format('select public.admin_delete_deduction_policy(%L)', pb));
  perform pg_temp.ok(s = 'policy_not_found', 'another company''s policy cannot be deleted', s);
  s := pg_temp.err(format('select public.admin_delete_deduction_policy(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'policy_not_found', 'deleting an unknown id', s);
  reset role;
  perform pg_temp.ok((select count(*) from public.deduction_policies where company_id = v_comp) = n0, 'refused calls saved nothing');
  perform pg_temp.ok((select count(*) from public.deduction_policies where company_id = v_other) = 1, 'the other company is untouched');

  -- edit a future policy; re-date the future policy to today: past days never change
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_save_deduction_policy(v_new, v_today + 12, 'proportional', '{"per_minutes":30,"deduct_minutes":15,"round_to":10,"rounding":"up"}');
  perform pg_temp.ok(r ->> 'id' = v_new::text and r ->> 'effective_from' = (v_today + 12)::text and (r -> 'params' ->> 'round_to')::int = 10, 'a future policy is edited in place', r::text);
  r := public.admin_save_deduction_policy(p2, v_today, 'tiers', tiers);
  perform pg_temp.ok(r ->> 'effective_from' = v_today::text, 'the future policy is re-dated to today', r::text);
  reset role;
  perform pg_temp.ok(private.late_deduction(v_comp, v_today - 3, 20) = 20, 'after re-dating, a past day still uses the first policy');
  perform pg_temp.ok(private.late_deduction(v_comp, v_today, 20) = 30, 'from today the re-dated policy applies');

  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  r := public.admin_list_deduction_policies();
  perform pg_temp.ok((select (x ->> 'editable')::boolean from jsonb_array_elements(r) x where x ->> 'id' = p2::text) = true, 'a policy starting today is still editable');
  perform public.admin_delete_deduction_policy(v_new2);
  perform pg_temp.ok(jsonb_array_length(public.admin_list_deduction_policies()) = 3, 'a future policy is deleted');
  reset role;
  perform pg_temp.ok(not exists (select 1 from public.deduction_policies where id = v_new2), 'it is gone from the table');

  -- the preview uses the company grace and rule (grace 15)
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform public.admin_set_grace_settings(15, 10);
  r := public.admin_preview_deduction(jsonb_build_object('kind', 'tiers', 'params', tiers), array[0, 5, 15, 16, 30, 31]);
  perform pg_temp.ok((select jsonb_agg((x ->> 'chargeable')::int) from jsonb_array_elements(r) x) = '[0,0,0,16,30,31]'::jsonb
                 and (select jsonb_agg((x ->> 'deduct')::int) from jsonb_array_elements(r) x) = '[0,0,0,30,30,60]'::jsonb, 'preview under all_after_grace', r::text);
  perform public.admin_set_late_rule('beyond_grace');
  r := public.admin_preview_deduction(jsonb_build_object('kind', 'tiers', 'params', tiers), array[0, 5, 15, 16, 30, 31]);
  perform pg_temp.ok((select jsonb_agg((x ->> 'chargeable')::int) from jsonb_array_elements(r) x) = '[0,0,0,1,15,16]'::jsonb
                 and (select jsonb_agg((x ->> 'deduct')::int) from jsonb_array_elements(r) x) = '[0,0,0,0,0,30]'::jsonb, 'preview under beyond_grace', r::text);
  perform pg_temp.ok((select jsonb_agg(x ->> 'late') from jsonb_array_elements(r) x) = '["0","5","15","16","30","31"]'::jsonb, 'preview keeps the order and the late value');
  r := public.admin_preview_deduction(jsonb_build_object('kind', 'proportional', 'params', '{"per_minutes":15,"deduct_minutes":10,"round_to":5,"rounding":"up"}'::jsonb), array[31]);
  v_prev := (r -> 0 ->> 'deduct')::int;
  s := pg_temp.err($q$select public.admin_preview_deduction(null, array[1])$q$);
  perform pg_temp.ok(s = 'invalid_settings', 'preview: no policy is refused', s);
  s := pg_temp.err($q$select public.admin_preview_deduction('{"kind":"tiers","params":{"tiers":[]}}', array[1])$q$);
  perform pg_temp.ok(s = 'invalid_settings', 'preview: a bad policy is refused', s);
  s := pg_temp.err(format('select public.admin_preview_deduction(%L, null)', jsonb_build_object('kind', 'tiers', 'params', tiers)::text));
  perform pg_temp.ok(s = 'invalid_settings', 'preview: no minutes is refused', s);
  s := pg_temp.err(format('select public.admin_preview_deduction(%L, array[-1])', jsonb_build_object('kind', 'tiers', 'params', tiers)::text));
  perform pg_temp.ok(s = 'invalid_settings', 'preview: negative minutes are refused', s);
  s := pg_temp.err(format('select public.admin_preview_deduction(%L, (select array_agg(g) from generate_series(1, 51) g))', jsonb_build_object('kind', 'tiers', 'params', tiers)::text));
  perform pg_temp.ok(s = 'invalid_settings', 'preview: more than 50 values are refused', s);
  reset role;
  perform pg_temp.ok(v_prev = private.deduction_calc('proportional', '{"per_minutes":15,"deduct_minutes":10,"round_to":5,"rounding":"up"}', 16), 'preview and the calculation agree (31 late, grace 15, beyond: 16 -> 15)', v_prev::text);

  -- an employee (not an admin) can do none of it
  perform pg_temp.as_user(a);
  set local role authenticated;
  s := pg_temp.err('select public.admin_list_deduction_policies()');
  perform pg_temp.ok(s <> '', 'an employee cannot list', s);
  s := pg_temp.err(format('select public.admin_save_deduction_policy(null, %L, ''tiers'', %L)', v_today + 40, tiers::text));
  perform pg_temp.ok(s <> '', 'an employee cannot save', s);
  s := pg_temp.err(format('select public.admin_delete_deduction_policy(%L)', v_new));
  perform pg_temp.ok(s <> '', 'an employee cannot delete', s);
  s := pg_temp.err(format('select public.admin_preview_deduction(%L, array[1])', jsonb_build_object('kind', 'tiers', 'params', tiers)::text));
  perform pg_temp.ok(s <> '', 'an employee cannot preview', s);
  s := pg_temp.err('select count(*) from public.deduction_policies');
  perform pg_temp.ok(s <> '', 'nobody reads the table directly', s);
  reset role;
  perform pg_temp.ok(exists (select 1 from public.deduction_policies where id = v_new), 'the employee attempts changed nothing');

  -- audit and grants
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'company.deduction_policy' and company_id = v_comp) = 4, 'each successful save is in the audit log (4)');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'company.deduction_policy_delete' and company_id = v_comp) = 1, 'each delete is in the audit log (1)');
  perform pg_temp.ok((select c.relrowsecurity from pg_class c where c.oid = 'public.deduction_policies'::regclass), 'row level security is on');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.deduction_policies', 'select') and not has_table_privilege('anon', 'public.deduction_policies', 'select'), 'no direct table grants');
  perform pg_temp.ok(not has_function_privilege('anon', 'public.admin_list_deduction_policies()', 'execute')
                 and not has_function_privilege('anon', 'public.admin_save_deduction_policy(uuid, date, text, jsonb)', 'execute')
                 and not has_function_privilege('anon', 'public.admin_delete_deduction_policy(uuid)', 'execute')
                 and not has_function_privilege('anon', 'public.admin_preview_deduction(jsonb, integer[])', 'execute'), 'anon cannot call the admin functions');
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_preview_deduction(jsonb, integer[])', 'execute'), 'authenticated can call them (the admin check is inside)');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.deduction_calc(text, jsonb, integer)', 'execute')
                 and not has_function_privilege('authenticated', 'private.late_deduction(uuid, date, integer)', 'execute')
                 and not has_function_privilege('authenticated', 'private.deduction_params_ok(text, jsonb)', 'execute'), 'the private functions are not callable by users');
  perform pg_temp.ok(true, 'END part 1');
end
$tests$;

-- ==================================================================== part 2: the deduction of one punch and the attendance list
do $tests2$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_tz text; base date; doff date; d1 date; d2 date; d3 date; d4 date; d5 date; d6 date;
  t_late uuid; t_range uuid;
  e1 uuid; e2 uuid; e3 uuid; e4 uuid; e5 uuid; e6 uuid; e_2nd uuid; e_out uuid; e_off uuid;
  j jsonb; row_x record;
  tiers jsonb := '{"tiers":[{"from":1,"to":15,"deduct":0},{"from":16,"to":30,"deduct":30},{"from":31,"to":null,"deduct":60}]}';
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select timezone into v_tz from public.companies where id = v_comp;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id <> v_admin and e.id <> a and e.company_id = v_comp order by employee_number limit 1;
  select id into t_late from public.permission_types where company_id = v_comp and mode = 'late_arrival' and is_active limit 1;
  select id into t_range from public.permission_types where company_id = v_comp and mode = 'range' and is_active limit 1;
  -- the fixture below saves more justifications than the seeded type allows per month (phase 19c refuses that at the table): lift the limit for this test only
  update public.permission_types set max_per_month = null where id = t_late;
  -- a known starting point: grace 15, the current rule, one tiers policy for every day
  update public.companies set late_grace_min = 15, early_grace_min = 10, late_rule = 'all_after_grace' where id = v_comp;
  update public.employees set late_grace_min = null, early_grace_min = null where id in (a, b);
  delete from public.deduction_policies where company_id = v_comp;
  base := (now() at time zone v_tz)::date - 12;
  insert into public.deduction_policies (company_id, effective_from, kind, params) values (v_comp, base - 100, 'tiers', tiers);
  doff := base; d1 := base + 1; d2 := base + 2; d3 := base + 3; d4 := base + 4; d5 := base + 5; d6 := base + 6;
  delete from public.employee_work_schedules where employee_id = a;
  insert into public.employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time, company_id)
  select a, g, g <> extract(dow from doff)::int, case when g <> extract(dow from doff)::int then time '08:00' end,
         case when g <> extract(dow from doff)::int then time '16:00' end, v_comp
  from generate_series(0, 6) g;

  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d1 + time '08:30:45') at time zone v_tz), true, 'password', 'none') returning id into e1;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d2 + time '08:30') at time zone v_tz), true, 'password', 'none') returning id into e2;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d3 + time '08:30') at time zone v_tz), true, 'password', 'none') returning id into e3;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d4 + time '08:30') at time zone v_tz), true, 'password', 'none') returning id into e4;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d5 + time '08:30') at time zone v_tz), true, 'password', 'none') returning id into e5;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d6 + time '08:15') at time zone v_tz), true, 'password', 'none') returning id into e6;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((d2 + time '13:00') at time zone v_tz), true, 'password', 'none') returning id into e_2nd;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_out', ((d2 + time '16:00') at time zone v_tz), true, 'password', 'none') returning id into e_out;
  insert into public.attendance_events (employee_id, event_type, occurred_at, within_geofence, authentication_method, location_policy) values (a, 'check_in', ((doff + time '09:30') at time zone v_tz), true, 'password', 'none') returning id into e_off;

  -- late-arrival justifications: start = the shift start, end = the arrival time the employee entered (HH:MM, no seconds)
  insert into public.requests (employee_id, request_type, status, start_at, end_at, company_id, permission_type_id, minutes)
  values (a, 'permission', 'approved', (d1 + time '08:00') at time zone v_tz, (d1 + time '08:30') at time zone v_tz, v_comp, t_late, 30),   -- d1: covers 08:30:45 (same minute)
         (b, 'permission', 'approved', (d2 + time '08:00') at time zone v_tz, (d2 + time '08:30') at time zone v_tz, v_comp, t_late, 30),   -- d2: somebody else's
         (a, 'permission', 'approved', (d3 + time '08:00') at time zone v_tz, (d3 + time '08:20') at time zone v_tz, v_comp, t_late, 20),   -- d3: entered an earlier time
         (a, 'permission', 'pending',  (d3 + time '08:00') at time zone v_tz, (d3 + time '08:25') at time zone v_tz, v_comp, t_late, 25),   -- d3: pending, also earlier
         (a, 'permission', 'pending',  (d4 + time '08:00') at time zone v_tz, (d4 + time '08:30') at time zone v_tz, v_comp, t_late, 30),   -- d4: pending, covers
         (a, 'permission', 'rejected', (d5 + time '08:00') at time zone v_tz, (d5 + time '08:30') at time zone v_tz, v_comp, t_late, 30),   -- d5: rejected
         (a, 'permission', 'cancelled',(d5 + time '08:00') at time zone v_tz, (d5 + time '08:30') at time zone v_tz, v_comp, t_late, 30),   -- d5: cancelled
         (a, 'permission', 'approved', (d5 + time '08:00') at time zone v_tz, (d5 + time '08:30') at time zone v_tz, v_comp, t_range, 30);  -- d5: another permission type

  j := private.punch_deduction(a, e1, (d1 + time '08:30:45') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'excused' and (j ->> 'minutes')::int = 0, 'approved justification covering the arrival minute (08:30 for 08:30:45): excused, 0', j::text);
  j := private.punch_deduction(a, e2, (d2 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'due' and (j ->> 'minutes')::int = 30, 'no justification (somebody else''s does not count): due 30', j::text);
  j := private.punch_deduction(a, e3, (d3 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'due' and (j ->> 'minutes')::int = 30, 'a justification that stops before the real arrival (approved or pending) does not excuse: due 30', j::text);
  j := private.punch_deduction(a, e4, (d4 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'pending' and (j ->> 'minutes')::int = 30, 'a pending justification that covers: pending with the provisional 30', j::text);
  j := private.punch_deduction(a, e5, (d5 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'due' and (j ->> 'minutes')::int = 30, 'rejected, cancelled and other-type permissions do not excuse: due 30', j::text);
  j := private.punch_deduction(a, e6, (d6 + time '08:15') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'none' and (j ->> 'minutes')::int = 0, 'within the grace: none, 0', j::text);
  perform pg_temp.ok(private.punch_deduction(a, e_2nd, (d2 + time '13:00') at time zone v_tz) is null, 'a second check-in has no deduction (null)');
  perform pg_temp.ok(private.punch_deduction(a, e_out, (d2 + time '16:00') at time zone v_tz) is null, 'a check-out has no deduction (null)');
  perform pg_temp.ok(private.punch_deduction(a, e_off, (doff + time '09:30') at time zone v_tz) is null, 'a day off has no deduction (null)');
  perform pg_temp.ok(private.punch_deduction(b, e2, (d2 + time '08:30') at time zone v_tz) is null, 'asking for somebody else''s event gives null');

  update public.companies set late_rule = 'beyond_grace' where id = v_comp;
  j := private.punch_deduction(a, e2, (d2 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'none' and (j ->> 'minutes')::int = 0, 'beyond_grace: 30 late = 15 chargeable = tier 1-15 = 0: none', j::text);
  update public.companies set late_rule = 'all_after_grace' where id = v_comp;

  -- the attendance list
  perform pg_temp.as_user(v_admin);
  set local role authenticated;
  perform pg_temp.ok(pg_get_function_result('public.admin_list_attendance(timestamptz, timestamptz, uuid, public.attendance_event_type, integer, integer)'::regprocedure)
    like '%late_minutes integer, early_minutes integer, deduction_minutes integer, deduction_state text)', 'list: the two new columns are last, the old ones keep their place');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e1;
  perform pg_temp.ok(row_x.late_minutes = 31 and row_x.deduction_minutes = 0 and row_x.deduction_state = 'excused', 'list: e1 late 31, excused, 0');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e2;
  perform pg_temp.ok(row_x.late_minutes = 30 and row_x.deduction_minutes = 30 and row_x.deduction_state = 'due', 'list: e2 late 30, due 30');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e4;
  perform pg_temp.ok(row_x.deduction_minutes = 30 and row_x.deduction_state = 'pending', 'list: e4 pending 30');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e6;
  perform pg_temp.ok(row_x.late_minutes = 0 and row_x.deduction_minutes = 0 and row_x.deduction_state = 'none', 'list: e6 within the grace: none');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_out;
  perform pg_temp.ok(row_x.deduction_minutes is null and row_x.deduction_state is null and row_x.early_minutes = 0 and row_x.late_minutes is null, 'list: a check-out has no deduction but keeps its early value');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_2nd;
  perform pg_temp.ok(row_x.deduction_minutes is null and row_x.deduction_state is null, 'list: a second check-in has none');
  select * into row_x from public.admin_list_attendance(null, null, a, null, 100, 0) x where x.event_id = e_off;
  perform pg_temp.ok(row_x.deduction_minutes is null and row_x.deduction_state is null, 'list: a day off has none');
  reset role;

  -- no policy: nothing to deduct
  delete from public.deduction_policies where company_id = v_comp;
  j := private.punch_deduction(a, e2, (d2 + time '08:30') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'none' and (j ->> 'minutes')::int = 0, 'no policy: none, 0', j::text);
  j := private.punch_deduction(a, e1, (d1 + time '08:30:45') at time zone v_tz);
  perform pg_temp.ok(j ->> 'state' = 'excused', 'no policy but an approved justification: still excused', j::text);
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.punch_deduction(uuid, uuid, timestamptz)', 'execute'), 'punch_deduction is not callable by users');
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
