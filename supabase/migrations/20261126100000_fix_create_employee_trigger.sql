-- Fix 2026-11-26: «إضافة موظف» in the admin panel always failed (create-employee answered 500, create_failed).
-- Cause: Supabase Auth's admin createUser INSERTs the new user with app_metadata = {provider, providers} only and writes the custom
-- app_metadata (company_id, company_role) with an UPDATE afterwards, in the same transaction. on_auth_user_created ran only
-- AFTER INSERT, so it never saw company_id and created no employee row; create-employee then called admin_save_employee_profile,
-- which answered employee_not_found, and the function deleted the new account.
-- Fix: the same trigger also runs AFTER UPDATE OF raw_app_meta_data, and the function creates the rows on an update ONLY when
-- company_id has just appeared (it was absent before) and the account has no employee row yet. So:
--   * createUser (insert, then update): the employee and the membership are created on the update, inside the same transaction;
--   * an INSERT that already carries company_id works exactly as before;
--   * every other update of an existing account (password change, reset, flags) does nothing at all, even in an inactive company.
-- Nothing else changes: same function name, same trigger name, same rows, same checks (invalid_company), owner and grants kept.
-- Rollback: 20261126100000_fix_create_employee_trigger_ROLLBACK.sql

do $guard$
begin
  if to_regprocedure('public.handle_new_auth_user()') is null
     or not exists (select 1 from pg_trigger where tgname = 'on_auth_user_created' and tgrelid = 'auth.users'::regclass) then
    raise exception 'fix_create_employee: expected objects are missing (public.handle_new_auth_user, trigger on_auth_user_created)';
  end if;
end
$guard$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_company uuid;
  v_role text;
  v_policy text;
begin
  -- On an update: only the moment company_id first appears on an account that is not an employee yet (Supabase Auth's createUser).
  if tg_op = 'UPDATE' then
    if nullif(old.raw_app_meta_data ->> 'company_id', '') is not null
       or nullif(new.raw_app_meta_data ->> 'company_id', '') is null
       or exists (select 1 from public.employees e where e.id = new.id) then
      return new;
    end if;
  end if;

  begin
    v_company := nullif(new.raw_app_meta_data ->> 'company_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception 'invalid_company' using errcode = '22023';
  end;
  if v_company is null then
    return new;
  end if;

  select c.default_location_policy into v_policy from public.companies c where c.id = v_company and c.is_active;
  if not found then
    raise exception 'invalid_company' using errcode = '22023';
  end if;
  v_role := case when new.raw_app_meta_data ->> 'company_role' = 'company_admin' then 'company_admin' else 'employee' end;

  insert into public.employees (id, company_id, employee_number, full_name, department, location_policy, geofence_required)
  values (
    new.id,
    v_company,
    'EMP-' || upper(substr(replace(new.id::text, '-', ''), 1, 8)),
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1), 'موظف جديد'),
    new.raw_user_meta_data ->> 'department',
    v_policy,
    v_policy = 'geofence'
  )
  on conflict (id) do nothing;

  insert into public.company_members (user_id, company_id, role)
  values (new.id, v_company, v_role)
  on conflict (user_id) do nothing;

  return new;
end;
$function$;
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

drop trigger on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of raw_app_meta_data on auth.users
  for each row execute function public.handle_new_auth_user();
