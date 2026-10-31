-- ============================================================================
-- Waqti Phase 4c: requests appear step by step (decided by Omar, 2026-10-31).
-- A request is seen only by the approver of its CURRENT step; the next approver sees it only after the
-- previous one approves. The employee app inbox already worked this way. This fixes the admin side:
--   * admin_list_requests: a company admin (HR) sees only requests that have REACHED an hr step
--     (hr step pending, approved or rejected). Requests still with a manager, rejected by a manager,
--     or cancelled before reaching HR are not shown.
--   * admin_decide_request: the admin decides only a request whose current step is hr
--     (no more deciding over a manager's step).
-- ============================================================================

do $guard$
begin
  if to_regclass('public.approval_steps') is null then
    raise exception 'phase 4 must be applied first';
  end if;
end
$guard$;

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
                and exists (select 1 from public.request_approvals a
                            where a.request_id = r.id and a.approver_kind = 'hr' and a.status in ('pending', 'approved', 'rejected'))
                and (p_status is null or r.status::text = p_status)
                and (p_type is null or r.request_type::text = p_type)
                and (p_employee_id is null or r.employee_id = p_employee_id)),
    'items', coalesce((
      select jsonb_agg(private.request_json(x.id) order by x.created_at desc)
      from (select r.id, r.created_at from public.requests r
            where r.company_id = v_company
              and exists (select 1 from public.request_approvals a
                          where a.request_id = r.id and a.approver_kind = 'hr' and a.status in ('pending', 'approved', 'rejected'))
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
  where a.request_id = p_request_id and r.company_id = v_company and a.status = 'pending' and a.approver_kind = 'hr';
  if not found then
    -- Already decided at the hr step: say so. Not (yet) at hr: it is not visible to the admin.
    if exists (select 1 from public.requests r
               join public.request_approvals a on a.request_id = r.id
               where r.id = p_request_id and r.company_id = v_company
                 and a.approver_kind = 'hr' and a.status in ('approved', 'rejected')) then
      raise exception 'already_decided' using errcode = 'P0001';
    end if;
    raise exception 'request_not_found' using errcode = '22023';
  end if;
  return private.apply_decision(v_ap.id, p_decision, p_note, auth.uid(), false);
end;
$$;

revoke execute on function public.admin_list_requests(text, text, uuid, integer, integer) from public, anon;
grant execute on function public.admin_list_requests(text, text, uuid, integer, integer) to authenticated;
revoke execute on function public.admin_decide_request(uuid, text, text) from public, anon;
grant execute on function public.admin_decide_request(uuid, text, text) to authenticated;
