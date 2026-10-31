-- ROLLBACK for 20261031090000_phase4c_progressive_visibility.sql
-- Restores admin_list_requests and admin_decide_request exactly as in phase 4
-- (the admin sees every request at once and can decide the current step, logged as an override).

create or replace function public.admin_list_requests(
  p_status text default null, p_type text default null, p_employee_id uuid default null,
  p_limit integer default 50, p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
begin
  return jsonb_build_object(
    'total', (select count(*) from public.requests r
              where r.company_id = v_company
                and (p_status is null or r.status::text = p_status)
                and (p_type is null or r.request_type::text = p_type)
                and (p_employee_id is null or r.employee_id = p_employee_id)),
    'items', coalesce((
      select jsonb_agg(private.request_json(x.id) order by x.created_at desc)
      from (select r.id, r.created_at from public.requests r
            where r.company_id = v_company
              and (p_status is null or r.status::text = p_status)
              and (p_type is null or r.request_type::text = p_type)
              and (p_employee_id is null or r.employee_id = p_employee_id)
            order by r.created_at desc
            limit greatest(least(coalesce(p_limit, 50), 500), 1) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb));
end;
$$;

create or replace function public.admin_decide_request(p_request_id uuid, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_company uuid := public.require_company_admin();
  v_ap public.request_approvals;
begin
  select a.* into v_ap from public.request_approvals a
  join public.requests r on r.id = a.request_id
  where a.request_id = p_request_id and r.company_id = v_company and a.status = 'pending';
  if not found then
    if exists (select 1 from public.requests where id = p_request_id and company_id = v_company) then
      raise exception 'already_decided' using errcode = 'P0001';
    end if;
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  return private.apply_decision(v_ap.id, p_decision, p_note, auth.uid(), v_ap.approver_kind <> 'hr');
end;
$$;
