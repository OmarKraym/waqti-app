-- Phase 24 tests (custom request kinds). Run by supabase/local/test-db.sh on a fresh database, after every migration.
-- Each do-block below is one task of docs/superpowers/plans/2026-11-10-custom-request-kinds.md; the last statement always raises
-- with the results. Uses real employees of company #1 and a second company for isolation checks.
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
-- the id of a kind of the admin's company, by name
create function pg_temp.kind(p_name text) returns uuid language plpgsql as $f$
declare r uuid;
begin
  select k.id into r from public.custom_request_kinds k
   where k.name = p_name
     and k.company_id = (select e.company_id from public.employees e join auth.users u on u.id = e.id
                         where lower(u.email) = lower(current_setting('waqti.admin_email')));
  return r;
end $f$;

-- a raw row in public.requests for employee waqti.t24_emp starting at waqti.t24_start; returns '' or the error text. Rows carry reason 'T24RAW'.
create function pg_temp.raw_req(p_type text, p_leave text, p_kind uuid, p_perm uuid default null) returns text language plpgsql as $f$
declare e uuid := current_setting('waqti.t24_emp')::uuid;
begin
  insert into public.requests (employee_id, request_type, leave_type, custom_kind_id, permission_type_id, status, start_at, end_at, reason, days, company_id)
  values (e, p_type::public.request_type, p_leave, p_kind, p_perm, 'pending',
          current_setting('waqti.t24_start')::timestamptz, current_setting('waqti.t24_start')::timestamptz + interval '1 day', 'T24RAW',
          case when p_type = 'leave' then 1 end, (select company_id from public.employees where id = e));
  return '';
exception when others then return sqlerrm;
end $f$;

-- ================================================================ Task 1: schema
do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; v_comp2 uuid;
  k_leave uuid; k_other uuid; k_x2 uuid; k_tmp uuid; v_perm uuid;
  v_start timestamptz := now() + interval '10 days';
  s text; n int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into v_perm from public.permission_types where company_id = v_comp limit 1;
  perform pg_temp.as_user(v_admin);
  v_comp2 := public.platform_create_company('شركة اختبار 24', 'Africa/Tripoli');

  perform pg_temp.ok(to_regclass('public.custom_request_kinds') is not null and to_regclass('public.custom_kind_entitlements') is not null,
    'both tables exist');
  if to_regclass('public.custom_request_kinds') is null or to_regclass('public.custom_kind_entitlements') is null then
    return;  -- red: stop cleanly instead of failing on the first insert
  end if;

  -- privileges and RLS
  perform pg_temp.ok((select bool_and(c.relrowsecurity) from pg_class c
                      where c.oid in ('public.custom_request_kinds'::regclass, 'public.custom_kind_entitlements'::regclass)),
    'row level security is on for both tables');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.custom_request_kinds', 'select')
    and not has_table_privilege('anon', 'public.custom_request_kinds', 'select')
    and not has_table_privilege('authenticated', 'public.custom_kind_entitlements', 'select')
    and not has_table_privilege('anon', 'public.custom_kind_entitlements', 'select'), 'no direct table access for anon/authenticated');

  -- valid rows
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, default_days, gender, reason_required)
                             values (%L, 'leave', 'اختبار إجازة', 10, 'all', false)$q$, v_comp));
  perform pg_temp.ok(s = '', 'a valid leave kind inserts', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode)
                             values (%L, 'other', 'اختبار طلب', 'single')$q$, v_comp));
  perform pg_temp.ok(s = '', 'a valid other kind inserts', s);
  k_leave := pg_temp.kind('اختبار إجازة');
  k_other := pg_temp.kind('اختبار طلب');
  perform pg_temp.ok(k_leave is not null and k_other is not null, 'the two kinds can be found by name');

  -- rejected rows: family-specific fields
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode) values (%L, 'leave', 'x1', 'single')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'leave kind with a date mode is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode, default_days) values (%L, 'other', 'x2', 'range', 5)$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'other kind with default days is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode, gender) values (%L, 'other', 'x3', 'range', 'female')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'other kind with a gender is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode, reason_required) values (%L, 'other', 'x4', 'range', true)$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'other kind with reason_required is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'other', 'x5')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'other kind without a date mode is rejected', s);

  -- rejected rows: single columns
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', '')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'empty name is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', '   ')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'blank name is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', repeat('ب', 61))$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'a 61-character name is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', repeat('ب', 60))$q$, v_comp));
  perform pg_temp.ok(s = '', 'a 60-character name is accepted', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, gender) values (%L, 'leave', 'x6', 'x')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'unknown gender is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, default_days) values (%L, 'leave', 'x7', 367)$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', '367 default days is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, default_days) values (%L, 'leave', 'x8', -1)$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'negative default days is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, default_days) values (%L, 'leave', 'x9', 0)$q$, v_comp));
  perform pg_temp.ok(s = '' and (select default_days from public.custom_request_kinds where name = 'x9' and company_id = v_comp) = 0,
    '0 default days is accepted and stays 0', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode) values (%L, 'other', 'x10', 'x')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'unknown date mode is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'x', 'x11')$q$, v_comp));
  perform pg_temp.ok(s like '%custom_request_kinds%', 'unknown family is rejected', s);

  -- name uniqueness inside a company and family (case and spaces ignored)
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', 'Test Kind')$q$, v_comp));
  perform pg_temp.ok(s = '', 'first Test Kind inserts', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', '  test kind ')$q$, v_comp));
  perform pg_temp.ok(s like '%duplicate key%', 'same name differing by case and spaces is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name, date_mode) values (%L, 'other', 'Test Kind', 'none')$q$, v_comp));
  perform pg_temp.ok(s = '', 'the same name is allowed in the other family', s);
  s := pg_temp.err(format($q$insert into public.custom_request_kinds (company_id, family, name) values (%L, 'leave', 'Test Kind')$q$, v_comp2));
  perform pg_temp.ok(s = '', 'the same name is allowed in another company', s);
  select id into k_x2 from public.custom_request_kinds where company_id = v_comp2 and name = 'Test Kind';

  -- per-employee days
  s := pg_temp.err(format($q$insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days) values (%L, %L, %L, 367)$q$, v_comp, k_leave, a));
  perform pg_temp.ok(s like '%custom_kind_entitlements%', '367 days for an employee is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days) values (%L, %L, %L, 5)$q$, v_comp, k_leave, a));
  perform pg_temp.ok(s = '', 'a valid employee override inserts', s);
  s := pg_temp.err(format($q$insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days) values (%L, %L, %L, 6)$q$, v_comp, k_leave, a));
  perform pg_temp.ok(s like '%duplicate key%', 'a second override for the same kind and employee is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days) values (%L, %L, %L, 5)$q$, v_comp2, k_x2, a));
  perform pg_temp.ok(s <> '', 'an employee of another company is rejected', s);
  s := pg_temp.err(format($q$insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days) values (%L, %L, %L, 5)$q$, v_comp, k_x2, a));
  perform pg_temp.ok(s <> '', 'a kind of another company is rejected', s);

  -- requests: shape of a row
  perform set_config('waqti.t24_emp', a::text, true);
  perform set_config('waqti.t24_start', v_start::text, true);
  s := pg_temp.raw_req('leave', 'custom', k_leave);
  perform pg_temp.ok(s = '', 'a custom leave row with a kind inserts', s);
  s := pg_temp.raw_req('leave', 'custom', null);
  perform pg_temp.ok(s like '%requests_custom_kind_shape%', 'leave_type custom without a kind is rejected', s);
  s := pg_temp.raw_req('leave', 'annual', k_leave);
  perform pg_temp.ok(s like '%requests_custom_kind_shape%', 'a kind with leave_type annual is rejected', s);
  s := pg_temp.raw_req('permission', null, k_leave, v_perm);
  perform pg_temp.ok(s like '%requests_custom_kind_shape%', 'a permission with a kind is rejected', s);
  s := pg_temp.raw_req('other', null, k_other);
  perform pg_temp.ok(s = '', 'an other request with a kind inserts', s);
  s := pg_temp.raw_req('other', null, null);
  perform pg_temp.ok(s = '', 'a plain other request (no kind) still inserts', s);
  s := pg_temp.raw_req('leave', 'bogus', null);
  perform pg_temp.ok(s like '%leave_type%', 'leave_type bogus is still rejected', s);
  s := pg_temp.raw_req('leave', 'custom', k_x2);
  perform pg_temp.ok(s like '%requests_custom_kind_same_company%', 'a kind of another company is rejected by the foreign key', s);
  s := pg_temp.err(format('delete from public.custom_request_kinds where id = %L', k_leave));
  perform pg_temp.ok(s like '%requests_custom_kind_same_company%', 'a kind that a request uses cannot be deleted', s);
  delete from public.requests where reason = 'T24RAW';

  -- approval_steps: one chain per kind, kept apart from the plain other chain
  delete from public.approval_steps where company_id = v_comp and request_type = 'other';
  insert into public.approval_steps (company_id, request_type, step_order, approver_kind) values (v_comp, 'other', 1, 'hr');
  s := pg_temp.err(format($q$insert into public.approval_steps (company_id, request_type, step_order, approver_kind, custom_kind_id) values (%L, 'other', 1, 'hr', %L)$q$, v_comp, k_other));
  perform pg_temp.ok(s = '', 'step 1 of a kind coexists with step 1 of the plain other chain', s);
  s := pg_temp.err(format($q$insert into public.approval_steps (company_id, request_type, step_order, approver_kind, custom_kind_id) values (%L, 'other', 1, 'direct_manager', %L)$q$, v_comp, k_other));
  perform pg_temp.ok(s like '%approval_steps_order_uidx%', 'a second step 1 for the same kind is rejected', s);
  s := pg_temp.err(format($q$insert into public.approval_steps (company_id, request_type, step_order, approver_kind, custom_kind_id) values (%L, 'leave', 1, 'hr', %L)$q$, v_comp, k_other));
  perform pg_temp.ok(s like '%approval_steps%', 'a kind on a leave chain row is rejected', s);
  s := pg_temp.err(format($q$insert into public.approval_steps (company_id, request_type, step_order, approver_kind, custom_kind_id, permission_type_id) values (%L, 'other', 2, 'hr', %L, %L)$q$, v_comp, k_other, v_perm));
  perform pg_temp.ok(s like '%approval_steps%', 'a row with both a permission type and a kind is rejected', s);
  insert into public.custom_request_kinds (company_id, family, name, date_mode) values (v_comp, 'other', 'مؤقت', 'none') returning id into k_tmp;
  insert into public.approval_steps (company_id, request_type, step_order, approver_kind, custom_kind_id) values (v_comp, 'other', 1, 'hr', k_tmp);
  insert into public.custom_kind_entitlements (company_id, kind_id, employee_id, days) values (v_comp, k_tmp, a, 1) on conflict do nothing;
  delete from public.custom_request_kinds where id = k_tmp;
  select count(*) into n from public.approval_steps where custom_kind_id = k_tmp;
  perform pg_temp.ok(n = 0, 'deleting an unused kind deletes its chain rows', n::text);
  delete from public.custom_request_kinds where id = k_leave;
  select count(*) into n from public.custom_kind_entitlements where kind_id = k_leave;
  perform pg_temp.ok(n = 0, 'deleting a kind deletes its employee overrides', n::text);
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
