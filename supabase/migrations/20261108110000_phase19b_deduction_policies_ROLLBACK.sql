-- Rollback of phase 19b: no deduction policies. The policies already saved are deleted with the table (they exist only
-- for the deduction, which nothing else uses yet).
drop function if exists public.admin_preview_deduction(jsonb, integer[]);
drop function if exists public.admin_delete_deduction_policy(uuid);
drop function if exists public.admin_save_deduction_policy(uuid, date, text, jsonb);
drop function if exists public.admin_list_deduction_policies();
drop function if exists private.deduction_policy_json(public.deduction_policies, date);
drop function if exists private.late_deduction(uuid, date, integer);
drop function if exists private.deduction_calc(text, jsonb, integer);
drop function if exists private.deduction_params_ok(text, jsonb);
drop function if exists private.deduction_params_clean(text, jsonb);
drop function if exists private.json_int(jsonb, integer, integer);
drop table if exists public.deduction_policies;
