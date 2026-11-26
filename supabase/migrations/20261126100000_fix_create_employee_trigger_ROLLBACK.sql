-- Rollback of the create-employee trigger fix (2026-11-26): the trigger runs AFTER INSERT only again, with the earlier function text.
-- Accounts created while the fix was in place stay as they are. Run it in one transaction (psql -1).

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
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_auth_user();
