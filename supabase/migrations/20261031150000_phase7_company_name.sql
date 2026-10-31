-- ============================================================================
-- Waqti Phase 7: the company admin renames the company (decided by Omar, 2026-10-31).
--
--   * New function only; nothing existing changes. The employee app already shows companies.name
--     (employee_attendance_state), so the new name appears there on the next refresh.
--   * Rules: one line, 2 to 150 characters after trimming (the table allows 1..150).
--   * Audit: old and new name.
-- ============================================================================

do $guard$
begin
  if to_regprocedure('public.admin_set_company_name(text)') is not null then
    raise exception 'phase 7 already applied';
  end if;
end
$guard$;

create function public.admin_set_company_name(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_name text := btrim(coalesce(p_name, ''));
  v_old text;
begin
  if length(v_name) not between 2 and 150 or v_name ~ '[[:cntrl:]]' then
    raise exception 'invalid_company_name' using errcode = '22023';
  end if;
  select name into v_old from public.companies where id = v_company for update;
  if v_old is distinct from v_name then
    update public.companies set name = v_name where id = v_company;
    perform public.audit_write(v_company, 'company.rename', 'company', v_company::text,
      jsonb_build_object('old_name', v_old, 'new_name', v_name));
  end if;
  return jsonb_build_object('name', v_name);
end;
$$;

revoke execute on function public.admin_set_company_name(text) from public, anon;
grant execute on function public.admin_set_company_name(text) to authenticated;
