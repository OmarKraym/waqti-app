-- Phase 24: custom request kinds.
-- The admin can add new LEAVE types and new «طلب آخر» types (a name and a few settings); the six built-in leave types and today's
-- «طلب آخر» are not touched. Spec: docs/superpowers/specs/2026-11-09-custom-request-kinds-design.md.
--   A. schema: custom_request_kinds, custom_kind_entitlements, requests.custom_kind_id, approval_steps.custom_kind_id
--   B. admin RPCs for kinds                          (added by the next task sections)
-- Rollback: …_ROLLBACK.sql (refuses to run once a request uses a kind).

-- ---------------------------------------------------------------- A. schema
create table public.custom_request_kinds (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  family text not null check (family in ('leave', 'other')),
  name text not null,
  enabled boolean not null default true,
  sort_order smallint not null default 0,
  default_days numeric(5, 1),                       -- leave only; NULL = unlimited, 0 = no days
  gender text not null default 'all',               -- leave only
  reason_required boolean not null default false,   -- leave only
  date_mode text,                                   -- other only
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint custom_request_kinds_company_id_key unique (company_id, id),
  constraint custom_request_kinds_name_check check (length(btrim(name)) between 1 and 60),
  constraint custom_request_kinds_days_check check (default_days is null or (default_days >= 0 and default_days <= 366)),
  constraint custom_request_kinds_gender_check check (gender in ('all', 'female', 'male')),
  constraint custom_request_kinds_date_mode_check check (date_mode is null or date_mode in ('single', 'range', 'none')),
  constraint custom_request_kinds_family_fields check (
    (family = 'leave' and date_mode is null)
    or (family = 'other' and date_mode is not null and default_days is null and gender = 'all' and reason_required = false))
);
create unique index custom_request_kinds_name_uidx on public.custom_request_kinds (company_id, family, lower(btrim(name)));

-- Per-employee days of a leave kind. No row = the kind's default_days.
create table public.custom_kind_entitlements (
  company_id uuid not null,
  kind_id uuid not null,
  employee_id uuid not null,
  days numeric(5, 1) not null,
  primary key (kind_id, employee_id),
  constraint custom_kind_entitlements_days_check check (days >= 0 and days <= 366),
  constraint custom_kind_entitlements_kind_same_company
    foreign key (company_id, kind_id) references public.custom_request_kinds (company_id, id) on delete cascade,
  constraint custom_kind_entitlements_employee_same_company
    foreign key (company_id, employee_id) references public.employees (company_id, id) on delete cascade
);

alter table public.custom_request_kinds enable row level security;
alter table public.custom_kind_entitlements enable row level security;
revoke all on public.custom_request_kinds, public.custom_kind_entitlements from anon, authenticated;

-- requests: the kind a request was made under. A custom leave carries leave_type = 'custom'.
alter table public.requests
  add column custom_kind_id uuid,
  add constraint requests_custom_kind_same_company
    foreign key (company_id, custom_kind_id) references public.custom_request_kinds (company_id, id) on delete restrict;
do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%annual%' loop
    execute format('alter table public.requests drop constraint %I', c);
  end loop;
end
$$;
alter table public.requests
  add constraint requests_leave_type_check
    check (leave_type in ('annual', 'sick', 'emergency', 'marriage', 'maternity', 'unpaid', 'custom')),
  add constraint requests_custom_kind_shape check (
    case request_type
      when 'leave' then (leave_type = 'custom') = (custom_kind_id is not null)
      when 'other' then true
      else custom_kind_id is null end);

-- approval_steps: a chain per custom «other» kind (custom leave kinds use the shared leave chain).
alter table public.approval_steps
  add column custom_kind_id uuid,
  add constraint approval_steps_custom_kind_same_company
    foreign key (company_id, custom_kind_id) references public.custom_request_kinds (company_id, id) on delete cascade,
  add constraint approval_steps_custom_kind_check check (custom_kind_id is null or (request_type = 'other' and permission_type_id is null));
drop index public.approval_steps_order_uidx;
create unique index approval_steps_order_uidx on public.approval_steps
  (company_id, request_type, coalesce(permission_type_id, '00000000-0000-0000-0000-000000000000'::uuid),
   coalesce(custom_kind_id, '00000000-0000-0000-0000-000000000000'::uuid), step_order);
