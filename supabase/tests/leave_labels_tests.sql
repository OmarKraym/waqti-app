-- Leave-type labels in the notification text (private.request_summary). The admin panel is the source of truth:
-- emergency = «اضطرارية», maternity = «وضع». The same map is pinned in the app (src/lib/requests.test.ts) and the
-- panel (tests/leave-labels.test.mjs), so the three cannot drift apart again.
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;

do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; v_id uuid; s text; t text; want text;
  v_map constant jsonb := '{"annual": "سنوية", "sick": "مرضية", "emergency": "اضطرارية", "marriage": "زواج", "maternity": "وضع", "unpaid": "بدون راتب"}';
  v_day timestamptz := (date_trunc('day', now()) + interval '40 days');
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  for t in select jsonb_object_keys(v_map) loop
    insert into public.requests (employee_id, request_type, leave_type, status, start_at, end_at, reason, days, company_id)
    values (a, 'leave', t, 'pending', v_day, v_day + interval '1 day', 'TLABELS', 1, v_comp)
    returning id into v_id;
    s := private.request_summary(v_id);
    want := 'إجازة ' || (v_map ->> t) || ' · ';
    perform pg_temp.ok(left(s, length(want)) = want, format('summary of a %s leave starts with «%s»', t, btrim(want, ' ·')), s);
    v_day := v_day + interval '2 days';
  end loop;
  -- the two words that changed must not survive anywhere in the function
  select p.prosrc into s from pg_proc p where p.oid = 'private.request_summary(uuid)'::regprocedure;
  perform pg_temp.ok(position('طارئة' in s) = 0 and position('أمومة' in s) = 0, 'request_summary no longer says «طارئة» or «أمومة»');
  -- unchanged around the fix: same security, volatility and search_path
  perform pg_temp.ok((select prosecdef and provolatile = 's' and proconfig = array['search_path=""']
                      from pg_proc where oid = 'private.request_summary(uuid)'::regprocedure),
    'request_summary is still security definer, stable, search_path empty');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'private.request_summary(uuid)', 'execute')
                     and not has_function_privilege('anon', 'private.request_summary(uuid)', 'execute'),
    'request_summary is still not executable by clients');
exception when others then
  insert into t_res (name, ok, detail) values ('a test block stopped on an error', false, sqlerrm);
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
