-- Rollback of phase 24. Run the sections from the LAST to the first. It refuses once a request uses a custom kind (nothing is lost silently).
do $$
begin
  if exists (select 1 from public.requests where custom_kind_id is not null) then
    raise exception 'rollback_refused_custom_requests_exist';
  end if;
end
$$;

-- ---------------------------------------------------------------- C. balance and days per employee
drop function public.admin_set_employee_kind_days(uuid, jsonb);
drop function public.admin_get_employee_kind_days(uuid);
drop function private.custom_leave_balance(uuid, uuid, integer, uuid);

-- ---------------------------------------------------------------- B. admin: the kinds
drop function public.admin_delete_custom_kind(uuid);
drop function public.admin_save_custom_kind(uuid, text, text, boolean, numeric, text, boolean, text, integer);
drop function public.admin_list_custom_kinds();

-- ---------------------------------------------------------------- A. schema
drop index public.approval_steps_order_uidx;
alter table public.approval_steps
  drop constraint approval_steps_custom_kind_check,
  drop constraint approval_steps_custom_kind_same_company,
  drop column custom_kind_id;
create unique index approval_steps_order_uidx on public.approval_steps
  (company_id, request_type, coalesce(permission_type_id, '00000000-0000-0000-0000-000000000000'::uuid), step_order);

alter table public.requests
  drop constraint requests_custom_kind_shape,
  drop constraint requests_leave_type_check,
  drop constraint requests_custom_kind_same_company,
  drop column custom_kind_id;
alter table public.requests
  add constraint requests_leave_type_check check (leave_type in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid'));

drop table public.custom_kind_entitlements;
drop table public.custom_request_kinds;
