-- Rollback of 20261102190000_phase16_admins.sql: the three functions and the helper are dropped.
-- Admins that were added or removed with them keep their role (company_members is not touched), and the audit rows stay.
drop function if exists public.admin_remove_admin(uuid);
drop function if exists public.admin_add_admin(uuid);
drop function if exists public.admin_list_admins();
drop function if exists private.working_admin_count(uuid, uuid);
