-- LOCAL TEST ONLY: synthetic data with the same shape as production (1 company, 1 admin who is also an employee,
-- active employees working Sat-Thu, 1 inactive employee, 1 entitlement row, 1 leave_policy row). No real people.
set search_path = public, extensions;
insert into private.app_secrets (name, value) values ('time_token_key', extensions.gen_random_bytes(32));
insert into companies (id, name) values ('c0000000-0000-4000-8000-000000000001', 'الشركة الرئيسية');
insert into leave_policy (company_id) values ('c0000000-0000-4000-8000-000000000001');
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
values ('a0000000-0000-4000-8000-000000000000', 'admin@example.com',
        '{"company_id":"c0000000-0000-4000-8000-000000000001","company_role":"company_admin"}', '{"full_name":"المدير"}');
insert into platform_admins (user_id) values ('a0000000-0000-4000-8000-000000000000');
insert into auth.users (email, raw_app_meta_data, raw_user_meta_data)
select 'emp' || g || '@example.com', '{"company_id":"c0000000-0000-4000-8000-000000000001"}', jsonb_build_object('full_name', 'موظف ' || g)
from generate_series(1, 67) g;
update employees e set employee_number = lpad(x.g::text, 3, '0'),
       gender = case when x.g in (5, 9) then 'female' when x.g = 12 then null else 'male' end,
       birth_date = case when x.g = 12 then null else date '1985-01-01' + x.g * 100 end
  from (select u.id, substring(u.email from 'emp(\d+)@')::int g from auth.users u where u.email like 'emp%') x
 where e.id = x.id;
update employees set employee_number = '000', gender = 'male', birth_date = '1980-05-05' where id = 'a0000000-0000-4000-8000-000000000000';
update employees set is_active = false where employee_number = '067';
insert into employee_work_schedules (employee_id, weekday, is_workday, start_time, end_time)
select e.id, d, d <> 5, case when d <> 5 then time '08:00' end, case when d <> 5 then time '16:00' end
from employees e cross join generate_series(0, 6) d where e.is_active;
insert into employee_leave_entitlements (employee_id, leave_type, days)
select id, 'annual', 25 from employees where employee_number = '020';
