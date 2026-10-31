-- Rollback of phase 7 (company rename by the company admin). Names already changed stay as they are.
drop function if exists public.admin_set_company_name(text);
