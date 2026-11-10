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

-- a raw custom-leave row of any status; returns its id (days = whole days from p_start, charged_days may be null)
create function pg_temp.raw_leave(p_emp uuid, p_kind uuid, p_status text, p_days numeric, p_charged numeric, p_start timestamptz)
  returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.requests (employee_id, request_type, leave_type, custom_kind_id, status, start_at, end_at, reason, days, charged_days, company_id)
  values (p_emp, 'leave', 'custom', p_kind, p_status::public.request_status, p_start, p_start + (ceil(p_days) || ' days')::interval, 'T24RAW', p_days, p_charged,
          (select company_id from public.employees where id = p_emp))
  returning id into v;
  return v;
end $f$;

-- a clean slate between blocks: requests made under kinds, kinds (and so their chains and overrides), the plain other chain
create function pg_temp.reset_kinds(p_company uuid) returns void language plpgsql as $f$
begin
  delete from public.requests where company_id = p_company and custom_kind_id is not null;
  delete from public.custom_request_kinds where company_id = p_company;
  delete from public.approval_steps where company_id = p_company and request_type = 'other';
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

-- ================================================================ Task 2: admin RPCs for kinds
do $tests$
declare
  v_admin uuid; a uuid; v_comp uuid; v_comp2 uuid;
  k1 uuid; k2 uuid; k_x2 uuid; k_del uuid;
  r jsonb; e jsonb; s text; n int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into v_comp2 from public.companies where name = 'شركة اختبار 24';
  perform pg_temp.reset_kinds(v_comp);
  perform set_config('waqti.t24_emp', a::text, true);
  perform set_config('waqti.t24_start', (now() + interval '10 days')::text, true);
  insert into public.custom_request_kinds (company_id, family, name) values (v_comp2, 'leave', 'Other Co Kind') returning id into k_x2;

  perform pg_temp.as_user(v_admin);
  s := pg_temp.err('select public.admin_list_custom_kinds()');
  perform pg_temp.ok(s not like '%does not exist%', 'admin_list_custom_kinds exists', s);
  if s like '%does not exist%' then return; end if;
  r := public.admin_list_custom_kinds();
  perform pg_temp.ok(r = '[]'::jsonb, 'the list starts empty', r::text);

  -- create and update
  k1 := public.admin_save_custom_kind(null, 'leave', 'إجازة دراسية', true, 15, 'all', false, null, 1);
  perform pg_temp.ok(k1 is not null, 'a leave kind is created and its id returned');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'custom_kind.create' and target_id = k1::text) = 1, 'create writes one audit row');
  r := public.admin_list_custom_kinds();
  e := r -> 0;
  perform pg_temp.ok(e ->> 'name' = 'إجازة دراسية' and e ->> 'family' = 'leave' and (e ->> 'default_days')::numeric = 15
    and e ->> 'gender' = 'all' and (e ->> 'reason_required')::boolean = false and (e ->> 'enabled')::boolean
    and (e ->> 'requests_count')::int = 0 and (e ->> 'pending_count')::int = 0, 'the list shows the kind with its settings and zero requests', e::text);
  perform public.admin_save_custom_kind(k1, 'leave', 'إجازة دراسية طويلة', true, 20, 'female', true, null, 2);
  e := (public.admin_list_custom_kinds()) -> 0;
  perform pg_temp.ok(e ->> 'name' = 'إجازة دراسية طويلة' and (e ->> 'default_days')::numeric = 20 and e ->> 'gender' = 'female'
    and (e ->> 'reason_required')::boolean and (e ->> 'sort_order')::int = 2, 'update changes the settings', e::text);
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'custom_kind.update' and target_id = k1::text) = 1, 'update writes one audit row');

  -- 0 days is not unlimited
  k2 := public.admin_save_custom_kind(null, 'leave', 'صفر', true, 0, 'all', false, null, 0);
  perform pg_temp.ok((select (x ->> 'default_days')::numeric from jsonb_array_elements(public.admin_list_custom_kinds()) x where x ->> 'id' = k2::text) = 0
    and (select x -> 'default_days' <> 'null'::jsonb from jsonb_array_elements(public.admin_list_custom_kinds()) x where x ->> 'id' = k2::text), '0 default days is stored as 0');
  perform public.admin_save_custom_kind(k2, 'leave', 'صفر', true, null, 'all', false, null, 0);
  perform pg_temp.ok((select x -> 'default_days' = 'null'::jsonb from jsonb_array_elements(public.admin_list_custom_kinds()) x where x ->> 'id' = k2::text), 'no default days is stored as NULL (unlimited)');

  -- refused input
  s := pg_temp.err(format($q$select public.admin_save_custom_kind(%L, 'other', 'x', true, null, 'all', false, 'single', 0)$q$, k1));
  perform pg_temp.ok(s = 'invalid_input', 'the family of a kind cannot change', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'ك1', true, 5, 'all', false, 'single', 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'a leave kind with a date mode is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'ك2', true, 5, 'all', false, 'single', 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an other kind with days is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'ك3', true, null, 'female', false, 'single', 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an other kind with a gender is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'ك4', true, null, 'all', true, 'single', 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an other kind with reason_required is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'ك5', true, null, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an other kind without a date mode is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'ك6', true, 5, 'x', false, null, 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an unknown gender is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'ك7', true, 367, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', '367 days is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'ك8', true, -1, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'negative days are refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'x', 'ك9', true, null, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an unknown family is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'ك10', true, 5, 'all', false, null, 1001)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'a sort order above 1000 is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'ك11', true, null, 'all', false, 'x', 0)$q$);
  perform pg_temp.ok(s = 'invalid_input', 'an unknown date mode is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', '   ', true, 5, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'invalid_name', 'a blank name is refused', s);
  s := pg_temp.err(format($q$select public.admin_save_custom_kind(null, 'leave', %L, true, 5, 'all', false, null, 0)$q$, repeat('ب', 61)));
  perform pg_temp.ok(s = 'invalid_name', 'a 61-character name is refused', s);

  -- names
  perform public.admin_save_custom_kind(null, 'leave', 'Study', true, 5, 'all', false, null, 0);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', '  study ', true, 5, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'kind_name_taken', 'the same name differing by case and spaces is refused', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'Study', true, null, 'all', false, 'range', 0)$q$);
  perform pg_temp.ok(s = '', 'the same name is allowed in the other family', s);
  s := pg_temp.err(format($q$select public.admin_save_custom_kind(%L, 'leave', 'Study', true, 5, 'all', false, null, 0)$q$, k1));
  perform pg_temp.ok(s = 'kind_name_taken', 'renaming onto another kind is refused', s);

  -- the 30-per-family limit (a family has 3 leave kinds now: k1, k2, Study)
  insert into public.custom_request_kinds (company_id, family, name)
  select v_comp, 'leave', 'حد ' || g from generate_series(1, 27) g;
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'الحادي والثلاثون', true, 5, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'kind_limit', 'the 31st leave kind is refused', s);
  s := pg_temp.err(format($q$select public.admin_save_custom_kind(%L, 'leave', 'إجازة دراسية طويلة', false, 20, 'female', true, null, 2)$q$, k1));
  perform pg_temp.ok(s = '', 'a kind can still be edited at the limit', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'other', 'طلب في الأخرى', true, null, 'all', false, 'none', 0)$q$);
  perform pg_temp.ok(s = '', 'the limit is per family', s);
  delete from public.custom_request_kinds where company_id = v_comp and name like 'حد %';

  -- counts and delete
  s := pg_temp.raw_req('leave', 'custom', k1);
  perform pg_temp.ok(s = '', 'a raw request under the kind', s);
  e := (select x from jsonb_array_elements(public.admin_list_custom_kinds()) x where x ->> 'id' = k1::text);
  perform pg_temp.ok((e ->> 'requests_count')::int = 1 and (e ->> 'pending_count')::int = 1, 'the list counts the requests of a kind', e::text);
  s := pg_temp.err(format('select public.admin_delete_custom_kind(%L)', k1));
  perform pg_temp.ok(s = 'kind_in_use', 'a kind with a request cannot be deleted', s);
  delete from public.requests where reason = 'T24RAW';
  k_del := public.admin_save_custom_kind(null, 'leave', 'للحذف', true, 1, 'all', false, null, 0);
  perform public.admin_delete_custom_kind(k_del);
  perform pg_temp.ok(not exists (select 1 from public.custom_request_kinds where id = k_del), 'an unused kind is deleted');
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'custom_kind.delete' and target_id = k_del::text) = 1, 'delete writes one audit row');

  -- isolation: a kind of another company
  s := pg_temp.err(format($q$select public.admin_save_custom_kind(%L, 'leave', 'Other Co Kind', true, 5, 'all', false, null, 0)$q$, k_x2));
  perform pg_temp.ok(s = 'custom_kind_not_found', 'a kind of another company cannot be updated', s);
  s := pg_temp.err(format('select public.admin_delete_custom_kind(%L)', k_x2));
  perform pg_temp.ok(s = 'custom_kind_not_found', 'a kind of another company cannot be deleted', s);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.admin_list_custom_kinds()) x where x ->> 'id' = k_x2::text),
    'the list never shows a kind of another company');
  s := pg_temp.err(format('select public.admin_delete_custom_kind(%L)', gen_random_uuid()));
  perform pg_temp.ok(s = 'custom_kind_not_found', 'an unknown kind id is not found', s);

  -- who may call
  perform pg_temp.as_user(a);
  s := pg_temp.err('select public.admin_list_custom_kinds()');
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot list kinds', s);
  s := pg_temp.err($q$select public.admin_save_custom_kind(null, 'leave', 'ممنوع', true, 5, 'all', false, null, 0)$q$);
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot save a kind', s);
  s := pg_temp.err(format('select public.admin_delete_custom_kind(%L)', k1));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot delete a kind', s);
  perform pg_temp.ok(
    has_function_privilege('authenticated', 'public.admin_list_custom_kinds()', 'execute')
    and has_function_privilege('authenticated', 'public.admin_save_custom_kind(uuid,text,text,boolean,numeric,text,boolean,text,integer)', 'execute')
    and has_function_privilege('authenticated', 'public.admin_delete_custom_kind(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.admin_list_custom_kinds()', 'execute')
    and not has_function_privilege('anon', 'public.admin_save_custom_kind(uuid,text,text,boolean,numeric,text,boolean,text,integer)', 'execute')
    and not has_function_privilege('anon', 'public.admin_delete_custom_kind(uuid)', 'execute'), 'authenticated may execute the three functions, anon may not');
end
$tests$;

-- ================================================================ Task 3: balance and per-employee days
do $tests$
declare
  v_admin uuid; a uuid; b uuid; v_comp uuid; v_comp2 uuid; v_emp2 uuid;
  kd uuid; ku uuid; kz uuid; ko uuid; kx2 uuid;
  v_s26 timestamptz := '2026-11-12 08:00+02'; v_s27 timestamptz := '2027-02-10 08:00+02';
  r jsonb; s text; rid uuid; n_before int;
begin
  select u.id into v_admin from auth.users u where lower(u.email) = lower(current_setting('waqti.admin_email'));
  select company_id into v_comp from public.employees where id = v_admin;
  select id into a from public.employees e where e.is_active and e.id <> v_admin and e.company_id = v_comp order by employee_number limit 1;
  select id into b from public.employees e where e.is_active and e.id not in (v_admin, a) and e.company_id = v_comp order by employee_number limit 1;
  select id into v_comp2 from public.companies where name = 'شركة اختبار 24';
  perform pg_temp.reset_kinds(v_comp);
  perform pg_temp.ok(to_regprocedure('private.custom_leave_balance(uuid,uuid,integer,uuid)') is not null
    and to_regprocedure('public.admin_set_employee_kind_days(uuid,jsonb)') is not null
    and to_regprocedure('public.admin_get_employee_kind_days(uuid)') is not null, 'the balance function and the two day RPCs exist');
  if to_regprocedure('private.custom_leave_balance(uuid,uuid,integer,uuid)') is null
     or to_regprocedure('public.admin_set_employee_kind_days(uuid,jsonb)') is null then return; end if;

  v_emp2 := gen_random_uuid();
  insert into auth.users (id, email) values (v_emp2, 't24-comp2@example.com');
  insert into public.employees (id, employee_number, full_name, company_id) values (v_emp2, 'T24-2', 'موظف الشركة الثانية', v_comp2);
  insert into public.custom_request_kinds (company_id, family, name) values (v_comp2, 'leave', 'Other Co Kind 3') returning id into kx2;

  perform pg_temp.as_user(v_admin);
  kd := public.admin_save_custom_kind(null, 'leave', 'رصيد عشرة', true, 10, 'all', false, null, 0);
  ku := public.admin_save_custom_kind(null, 'leave', 'غير محدود', true, null, 'all', false, null, 0);
  kz := public.admin_save_custom_kind(null, 'leave', 'صفر أيام', true, 0, 'all', false, null, 0);
  ko := public.admin_save_custom_kind(null, 'other', 'نوع آخر', true, null, 'all', false, 'single', 0);

  -- the balance of a fresh kind
  r := private.custom_leave_balance(a, kd, 2026);
  perform pg_temp.ok((r ->> 'entitled')::numeric = 10 and (r ->> 'used')::numeric = 0 and (r ->> 'pending')::numeric = 0
    and (r ->> 'remaining')::numeric = 10 and r ->> 'leave_type' = 'custom' and r ->> 'custom_kind_id' = kd::text, 'a fresh kind: 10 entitled, 10 remaining', r::text);
  r := private.custom_leave_balance(a, ku, 2026);
  perform pg_temp.ok(r -> 'entitled' = 'null'::jsonb and r -> 'remaining' = 'null'::jsonb, 'an unlimited kind: entitled and remaining are null', r::text);
  r := private.custom_leave_balance(a, kz, 2026);
  perform pg_temp.ok((r ->> 'entitled')::numeric = 0 and (r ->> 'remaining')::numeric = 0, 'a kind with 0 days: remaining is 0, not null', r::text);

  -- per-employee override
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kd::text, 5));
  r := private.custom_leave_balance(a, kd, 2026);
  perform pg_temp.ok((r ->> 'entitled')::numeric = 5 and (r ->> 'remaining')::numeric = 5, 'an override of 5 beats the default of 10', r::text);
  perform pg_temp.ok((private.custom_leave_balance(b, kd, 2026) ->> 'entitled')::numeric = 10, 'the override of one employee does not touch another');
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kd::text, 0));
  r := private.custom_leave_balance(a, kd, 2026);
  perform pg_temp.ok((r ->> 'entitled')::numeric = 0 and (r ->> 'remaining')::numeric = 0, 'an override of 0 is 0 days, not the default', r::text);
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kd::text, null));
  perform pg_temp.ok((private.custom_leave_balance(a, kd, 2026) ->> 'entitled')::numeric = 10, 'a null value removes the override (back to the default)');

  -- what is counted
  perform pg_temp.raw_leave(a, kd, 'approved', 2, null, v_s26);
  perform pg_temp.raw_leave(a, kd, 'approved', 3, 1.5, v_s26 + interval '10 days');
  rid := pg_temp.raw_leave(a, kd, 'pending', 2, null, v_s26 + interval '20 days');
  perform pg_temp.raw_leave(a, kd, 'cancelled', 4, null, v_s26 + interval '30 days');
  perform pg_temp.raw_leave(a, kd, 'rejected', 4, null, v_s26 + interval '40 days');
  perform pg_temp.raw_leave(a, kd, 'approved', 3, null, v_s27);
  perform pg_temp.raw_leave(b, kd, 'approved', 5, null, v_s26);
  r := private.custom_leave_balance(a, kd, 2026);
  perform pg_temp.ok((r ->> 'used')::numeric = 3.5, 'used = approved days, with charged_days where HR set it (2 + 1.5)', r::text);
  perform pg_temp.ok((r ->> 'pending')::numeric = 2, 'pending counts the pending request only', r::text);
  perform pg_temp.ok((r ->> 'remaining')::numeric = 4.5, 'remaining = 10 - 3.5 - 2', r::text);
  perform pg_temp.ok((private.custom_leave_balance(a, kd, 2027) ->> 'used')::numeric = 3, 'another year counts for its own year');
  perform pg_temp.ok((private.custom_leave_balance(a, kd, 2026, rid) ->> 'pending')::numeric = 0, 'p_exclude_request leaves that request out');
  perform pg_temp.ok((private.custom_leave_balance(b, kd, 2026) ->> 'used')::numeric = 5, 'another employee has his own count');
  perform pg_temp.ok((private.custom_leave_balance(a, ku, 2026) ->> 'used')::numeric = 0, 'requests of another kind are not counted');
  s := pg_temp.err(format('select private.custom_leave_balance(%L, %L, 2026)', a, gen_random_uuid()));
  perform pg_temp.ok(s = 'custom_kind_not_found', 'an unknown kind is an error, not an unlimited balance', s);
  delete from public.requests where reason = 'T24RAW';

  -- admin RPCs: get, partial maps
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kd::text, 3, kz::text, 2));
  r := public.admin_get_employee_kind_days(a);
  perform pg_temp.ok((r ->> kd::text)::numeric = 3 and (r ->> kz::text)::numeric = 2 and not r ? ku::text, 'get returns the overrides only', r::text);
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kz::text, null));
  r := public.admin_get_employee_kind_days(a);
  perform pg_temp.ok((r ->> kd::text)::numeric = 3 and not r ? kz::text, 'only the given keys change', r::text);
  perform pg_temp.ok(public.admin_get_employee_kind_days(b) = '{}'::jsonb, 'an employee without overrides gets an empty object');

  -- audit
  select count(*) into n_before from public.audit_log where action = 'custom_kind.days_set' and target_id = a::text;
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kd::text, 4));
  perform pg_temp.ok((select count(*) from public.audit_log where action = 'custom_kind.days_set' and target_id = a::text) = n_before + 1, 'setting days writes one audit row');

  -- refusals
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kx2::text, 3)));
  perform pg_temp.ok(s = 'custom_kind_not_found', 'a kind of another company is not found', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', v_emp2, jsonb_build_object(kd::text, 3)));
  perform pg_temp.ok(s = 'employee_not_found', 'an employee of another company is not found', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', gen_random_uuid(), jsonb_build_object(kd::text, 3)));
  perform pg_temp.ok(s = 'employee_not_found', 'an unknown employee is not found', s);
  s := pg_temp.err(format('select public.admin_get_employee_kind_days(%L)', v_emp2));
  perform pg_temp.ok(s = 'employee_not_found', 'overrides of an employee of another company cannot be read', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kd::text, 367)));
  perform pg_temp.ok(s = 'invalid_input', '367 days is refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kd::text, -1)));
  perform pg_temp.ok(s = 'invalid_input', 'negative days are refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kd::text, 2.25)));
  perform pg_temp.ok(s = 'invalid_input', 'days that do not fit one decimal are refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kd::text, 'abc')));
  perform pg_temp.ok(s = 'invalid_input', 'a text value is refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(ko::text, 3)));
  perform pg_temp.ok(s = 'invalid_input', 'a kind of the other family is refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object('not-a-uuid', 3)));
  perform pg_temp.ok(s = 'invalid_input', 'a key that is not a uuid is refused', s);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, '[1]'));
  perform pg_temp.ok(s = 'invalid_input', 'an array instead of an object is refused', s);
  perform public.admin_set_employee_kind_days(a, jsonb_build_object(kd::text, 4));
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kd::text, 9, ko::text, 3)));
  perform pg_temp.ok(s = 'invalid_input' and (public.admin_get_employee_kind_days(a) ->> kd::text)::numeric = 4, 'a refused map changes nothing', s);

  -- who may call
  perform pg_temp.as_user(a);
  s := pg_temp.err(format('select public.admin_set_employee_kind_days(%L, %L::jsonb)', a, jsonb_build_object(kd::text, 30)));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot set days', s);
  s := pg_temp.err(format('select public.admin_get_employee_kind_days(%L)', a));
  perform pg_temp.ok(s = 'forbidden', 'an employee cannot read overrides', s);
  perform pg_temp.ok(has_function_privilege('authenticated', 'public.admin_set_employee_kind_days(uuid,jsonb)', 'execute')
    and has_function_privilege('authenticated', 'public.admin_get_employee_kind_days(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.admin_set_employee_kind_days(uuid,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.admin_get_employee_kind_days(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'private.custom_leave_balance(uuid,uuid,integer,uuid)', 'execute')
    and not has_function_privilege('anon', 'private.custom_leave_balance(uuid,uuid,integer,uuid)', 'execute'), 'grants: admin RPCs for authenticated only, the balance for nobody');
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
