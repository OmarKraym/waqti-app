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
