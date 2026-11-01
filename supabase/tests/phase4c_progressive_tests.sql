-- Runs inside one transaction and always ends with an exception, so nothing is kept.
\if :{?admin_email}
\else
  \echo 'usage: psql -v admin_email=<company admin email> -f <this file>'
  \quit
\endif
select set_config('waqti.admin_email', :'admin_email', false) \g /dev/null
create temp table t_res (n serial, name text, ok boolean, detail text);
create function pg_temp.ok(c boolean, name text, detail text default null) returns void language sql as
  $$ insert into t_res (name, ok, detail) values (name, coalesce(c, false), detail) $$;
create function pg_temp.as_user(u uuid) returns void language sql as
  $$ select set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.err(q text) returns text language plpgsql as $$
begin execute q; return ''; exception when others then return sqlerrm; end $$;
create function pg_temp.listed(id text) returns boolean language sql as
  $$ select exists (select 1 from jsonb_array_elements(public.admin_list_requests(null, null, null, 500, 0) -> 'items') x where x ->> 'id' = id) $$;
create function pg_temp.in_inbox(id text) returns boolean language sql as
  $$ select exists (select 1 from jsonb_array_elements(public.approver_inbox()) x where x ->> 'id' = id) $$;
create function pg_temp.ap(id text) returns uuid language sql as
  $$ select (x ->> 'approval_id')::uuid from jsonb_array_elements(public.approver_inbox()) x where x ->> 'id' = id $$;

do $tests$
declare
  v_admin uuid; a uuid; b uuid; c uuid; d uuid; r jsonb; rid text; s text;
  v_mon date := (now() at time zone 'Africa/Tripoli')::date + 21;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select id into a from public.employees e where e.is_active and e.id <> v_admin order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) order by employee_number offset 1 limit 1;
  select id into c from public.employees e where e.is_active and e.id not in (v_admin, a, b) order by employee_number offset 2 limit 1;
  select id into d from public.employees e where e.is_active and e.id not in (v_admin, a, b, c) order by employee_number offset 3 limit 1;
  perform pg_temp.as_user(v_admin);
  perform public.admin_set_employee_manager(a, b);
  perform public.admin_set_employee_manager(b, c);
  perform public.admin_set_approval_chain('leave', '[{"kind":"direct_manager"},{"kind":"second_manager"},{"kind":"hr"}]');

  -- A asks; path: B (manager) -> C (manager's manager) -> HR
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_mon, v_mon);
  rid := r ->> 'id';
  perform pg_temp.as_user(b);
  perform pg_temp.ok(pg_temp.in_inbox(rid), 'step 1: the direct manager sees it');
  perform pg_temp.as_user(c);
  perform pg_temp.ok(not pg_temp.in_inbox(rid), 'step 1: the next approver does NOT see it yet');
  perform pg_temp.as_user(v_admin);
  perform pg_temp.ok(not pg_temp.listed(rid), 'step 1: HR does NOT see it in the admin list');
  s := pg_temp.err(format($q$select public.admin_decide_request(%L, 'approve')$q$, rid));
  perform pg_temp.ok(s = 'request_not_found', 'step 1: HR cannot decide it before it reaches HR', s);

  perform pg_temp.as_user(b);
  perform public.approver_decide(pg_temp.ap(rid), 'approve');
  perform pg_temp.ok(not pg_temp.in_inbox(rid), 'after approving, the manager no longer has it to decide');
  perform pg_temp.as_user(c);
  perform pg_temp.ok(pg_temp.in_inbox(rid), 'step 2: now the next approver sees it');
  perform pg_temp.as_user(v_admin);
  perform pg_temp.ok(not pg_temp.listed(rid), 'step 2: HR still does not see it');

  perform pg_temp.as_user(c);
  perform public.approver_decide(pg_temp.ap(rid), 'approve');
  perform pg_temp.as_user(v_admin);
  perform pg_temp.ok(pg_temp.listed(rid), 'step 3: HR sees it once it reaches HR');
  r := public.admin_decide_request(rid::uuid, 'approve');
  perform pg_temp.ok(r ->> 'status' = 'approved', 'HR approves it -> approved', r::text);
  perform pg_temp.ok(pg_temp.listed(rid), 'decided at HR: stays in the HR list (history)');
  s := pg_temp.err(format($q$select public.admin_decide_request(%L, 'approve')$q$, rid));
  perform pg_temp.ok(s = 'already_decided', 'deciding again: already_decided', s);

  -- rejected by the manager: HR never sees it
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_mon + 7, v_mon + 7);
  rid := r ->> 'id';
  perform pg_temp.as_user(b);
  perform public.approver_decide(pg_temp.ap(rid), 'reject', 'لا');
  perform pg_temp.as_user(v_admin);
  perform pg_temp.ok(not pg_temp.listed(rid), 'rejected by the manager: never shown to HR');
  perform pg_temp.ok(not pg_temp.listed(rid) and (select count(*) from public.requests where requests.id = rid::uuid) = 1, 'the request itself still exists');

  -- cancelled while with the manager: HR never sees it
  perform pg_temp.as_user(a);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_mon + 14, v_mon + 14);
  rid := r ->> 'id';
  perform public.employee_cancel_request(rid::uuid);
  perform pg_temp.as_user(v_admin);
  perform pg_temp.ok(not pg_temp.listed(rid), 'cancelled before reaching HR: not shown to HR');

  -- no manager: goes straight to HR, so HR sees it at once
  perform pg_temp.as_user(d);
  r := public.employee_submit_request(gen_random_uuid(), 'leave', 'unpaid', v_mon + 21, v_mon + 21);
  rid := r ->> 'id';
  perform pg_temp.as_user(v_admin);
  perform pg_temp.ok(pg_temp.listed(rid), 'no manager (step skipped): HR sees it at once');
  perform pg_temp.ok(pg_temp.in_inbox(rid), '...and in the app inbox too');
  perform pg_temp.ok((public.admin_list_requests('pending') ->> 'total')::int
                     = jsonb_array_length(public.admin_list_requests('pending', null, null, 500, 0) -> 'items'), 'total counts only visible requests');

  perform set_config('role', 'authenticated', true);
  s := pg_temp.err('select public.admin_list_requests()');
  perform set_config('role', 'none', true);
  perform pg_temp.ok(s = '', 'works under the authenticated role', s);
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
