-- ============================================================================
-- Waqti Phase 5: notifications (decided by Omar, 2026-10-31).
--
--   * Web Push to the employee app (PWA). A phone subscribes once ("تفعيل الإشعارات"); one employee can have
--     several devices. Everything is SENT BY THE SERVER: a web app cannot schedule alarms on the phone.
--   * Requests (always on): when a step becomes pending, its approver(s) get "طلب بانتظار موافقتك"
--     (step by step, following the approval path: the next approver is notified only after the previous one
--     approves). HR steps go to every active company admin (never to the requester himself).
--     When the request is finally approved or rejected, the requester is notified (with the rejection note).
--   * Attendance reminders (each employee turns them on): N minutes before his shift start (check-in) and
--     before his shift end (check-out), following his own weekly schedule. Not sent when there is no reason:
--     check-in reminder only if he has not checked in that day and is not on approved leave; check-out
--     reminder only if he is checked in. Each reminder at most once per day.
--   * Outbox: notifications are queued in public.notifications and sent by the send-push Edge Function
--     (claimed in batches, retried up to 5 times, dead subscriptions removed). Scheduling (pg_cron, pg_net)
--     is in the next migration (production only).
-- ============================================================================

do $guard$
begin
  if to_regclass('public.permission_types') is null then
    raise exception 'phase 4d must be applied first';
  end if;
  if to_regclass('public.notifications') is not null then
    raise exception 'phase 5 already applied';
  end if;
end
$guard$;

-- ---------------------------------------------------------------- 1. Tables
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  endpoint text not null unique check (endpoint ~ '^https://' and length(endpoint) <= 1000),
  p256dh text not null check (length(p256dh) between 80 and 100),
  auth text not null check (length(auth) between 16 and 30),
  user_agent text check (user_agent is null or length(user_agent) <= 300),
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  fail_count smallint not null default 0
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);

create table public.notification_settings (
  employee_id uuid primary key references public.employees (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  remind_check_in boolean not null default false,
  check_in_before smallint not null default 10 check (check_in_before between 0 and 120),
  remind_check_out boolean not null default false,
  check_out_before smallint not null default 0 check (check_out_before between 0 and 120),
  updated_at timestamptz not null default now()
);

create table public.notifications (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('approval_needed', 'request_decided', 'reminder_check_in', 'reminder_check_out', 'test')),
  title text not null check (length(title) <= 120),
  body text not null check (length(body) <= 400),
  url text not null default './' check (length(url) <= 200),
  tag text check (tag is null or length(tag) <= 64),
  ttl_seconds integer not null default 86400 check (ttl_seconds between 60 and 2419200),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  attempts smallint not null default 0,
  sent_at timestamptz,
  last_error text
);
create index notifications_outbox_idx on public.notifications (created_at) where sent_at is null;
create index notifications_user_idx on public.notifications (user_id, created_at desc);

create table public.reminder_log (
  employee_id uuid not null references public.employees (id) on delete cascade,
  day date not null,
  kind text not null check (kind in ('check_in', 'check_out')),
  created_at timestamptz not null default now(),
  primary key (employee_id, day, kind)
);

alter table public.push_subscriptions enable row level security;
alter table public.notification_settings enable row level security;
alter table public.notifications enable row level security;
alter table public.reminder_log enable row level security;
revoke all on public.push_subscriptions, public.notification_settings, public.notifications, public.reminder_log from anon, authenticated;

-- ---------------------------------------------------------------- 2. Queue a notification
create or replace function private.notify(p_user uuid, p_company uuid, p_kind text, p_title text, p_body text,
                                          p_url text default './', p_tag text default null, p_ttl integer default 86400)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notifications (company_id, user_id, kind, title, body, url, tag, ttl_seconds)
  values (p_company, p_user, p_kind, left(p_title, 120), left(p_body, 400), p_url, p_tag, p_ttl)
$$;
revoke all on function private.notify(uuid, uuid, text, text, text, text, text, integer) from public, anon, authenticated;

-- "يوم واحد", "يومان", "3 أيام", "11 يومًا"
create or replace function private.days_text(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p is null then ''
    when p <> trunc(p) then p::text || ' يوم'
    when p = 1 then 'يوم واحد'
    when p = 2 then 'يومان'
    when p between 3 and 10 then p::int || ' أيام'
    else p::int || ' يومًا' end
$$;
revoke all on function private.days_text(numeric) from public, anon, authenticated;

-- One line describing a request, e.g. "إجازة سنوية · 3 أيام · 09/11 – 11/11", "إذن: تبرير تأخير · 31/10 08:00–08:20".
create or replace function private.request_summary(p_request uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case r.request_type
    when 'leave' then
      'إجازة ' || case r.leave_type when 'annual' then 'سنوية' when 'sick' then 'مرضية' when 'emergency' then 'طارئة'
                                    when 'marriage' then 'زواج' when 'maternity' then 'أمومة' when 'unpaid' then 'بدون راتب' else '' end
      || ' · ' || private.days_text(r.days) || ' · '
      || to_char(r.start_at at time zone c.timezone, 'DD/MM')
      || case when (r.end_at - interval '1 second') at time zone c.timezone >= (r.start_at at time zone c.timezone)::date + 1
              then ' – ' || to_char((r.end_at - interval '1 second') at time zone c.timezone, 'DD/MM') else '' end
    when 'permission' then
      'إذن: ' || coalesce(pt.name, '') || ' · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM HH24:MI')
      || '–' || to_char(r.end_at at time zone c.timezone, 'HH24:MI')
    else
      'طلب آخر · ' || to_char(r.start_at at time zone c.timezone, 'DD/MM')
  end
  from public.requests r
  join public.companies c on c.id = r.company_id
  left join public.permission_types pt on pt.id = r.permission_type_id
  where r.id = p_request
$$;
revoke all on function private.request_summary(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. Requests: notify step by step
-- A step that becomes pending -> its approver (or every active company admin for an hr step).
create or replace function private.on_approval_pending()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
  v_name text;
  v_body text;
  v_user uuid;
begin
  if new.status <> 'pending' or (tg_op = 'UPDATE' and old.status = 'pending') then
    return null;
  end if;
  select * into v_req from public.requests where id = new.request_id;
  select full_name into v_name from public.employees where id = v_req.employee_id;
  v_body := v_name || ': ' || private.request_summary(new.request_id);
  for v_user in
    select new.approver_employee_id where new.approver_kind <> 'hr' and new.approver_employee_id is not null
    union
    select m.user_id from public.company_members m
    join public.employees e on e.id = m.user_id and e.is_active
    where new.approver_kind = 'hr' and m.company_id = new.company_id and m.role = 'company_admin'
  loop
    if v_user <> v_req.employee_id then
      perform private.notify(v_user, new.company_id, 'approval_needed', 'طلب بانتظار موافقتك', v_body,
                             '?tab=requests', 'approval-' || new.request_id::text, 86400 * 7);
    end if;
  end loop;
  return null;
end;
$$;
revoke all on function private.on_approval_pending() from public, anon, authenticated;
create trigger request_approvals_notify after insert or update of status on public.request_approvals
  for each row execute function private.on_approval_pending();

-- The final decision -> the requester.
create or replace function private.on_request_decided()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status in ('approved', 'rejected') then
    perform private.notify(new.employee_id, new.company_id, 'request_decided',
      case when new.status = 'approved' then 'تمت الموافقة على طلبك' else 'رُفض طلبك' end,
      private.request_summary(new.id)
        || case when new.status = 'rejected' and new.decision_note is not null then E'\nالسبب: ' || new.decision_note else '' end,
      '?tab=requests', 'request-' || new.id::text, 86400 * 7);
  end if;
  return null;
end;
$$;
revoke all on function private.on_request_decided() from public, anon, authenticated;
create trigger requests_notify_decision after update of status on public.requests
  for each row execute function private.on_request_decided();

-- ---------------------------------------------------------------- 4. Attendance reminders
-- Queues the reminders that are due (called every minute by the scheduler). Returns how many were queued.
-- A reminder is due from its time until 15 minutes later (so a late scheduler run still sends it once).
create or replace function private.enqueue_due_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select s.employee_id, s.company_id, s.remind_check_in, s.check_in_before, s.remind_check_out, s.check_out_before,
           c.timezone, (p_now at time zone c.timezone)::date as day, b.shift_start, b.shift_end
    from public.notification_settings s
    join public.employees e on e.id = s.employee_id and e.is_active
    join public.companies c on c.id = s.company_id and c.is_active
    cross join lateral private.shift_bounds(s.employee_id, (p_now at time zone c.timezone)::date, c.timezone) b
    where (s.remind_check_in or s.remind_check_out)
      and exists (select 1 from public.push_subscriptions p where p.user_id = s.employee_id)
  loop
    -- check-in: before the shift start, only if not checked in today and not on approved leave
    if r.remind_check_in
       and p_now >= r.shift_start - make_interval(mins => r.check_in_before)
       and p_now < r.shift_start - make_interval(mins => r.check_in_before) + interval '15 minutes'
       and not exists (select 1 from public.attendance_events ev
                       where ev.employee_id = r.employee_id and ev.event_type = 'check_in'
                         and (ev.occurred_at at time zone r.timezone)::date = r.day)
       and not exists (select 1 from public.attendance_sessions se where se.employee_id = r.employee_id and se.status = 'open')
       and not exists (select 1 from public.requests q
                       where q.employee_id = r.employee_id and q.request_type = 'leave' and q.status = 'approved'
                         and q.start_at <= r.shift_start and q.end_at > r.shift_start) then
      insert into public.reminder_log (employee_id, day, kind) values (r.employee_id, r.day, 'check_in') on conflict do nothing;
      if found then
        perform private.notify(r.employee_id, r.company_id, 'reminder_check_in', 'تذكير بتسجيل الحضور',
          case when r.check_in_before = 0 then 'بدأ دوامك الآن (' else 'يبدأ دوامك الساعة ' end
            || to_char(r.shift_start at time zone r.timezone, 'HH24:MI')
            || case when r.check_in_before = 0 then '). ' else '. ' end || 'لا تنسَ تسجيل الحضور.',
          './', 'reminder-in', 900);
        v_count := v_count + 1;
      end if;
    end if;

    -- check-out: before the shift end, only if checked in (open session)
    if r.remind_check_out
       and p_now >= r.shift_end - make_interval(mins => r.check_out_before)
       and p_now < r.shift_end - make_interval(mins => r.check_out_before) + interval '15 minutes'
       and exists (select 1 from public.attendance_sessions se where se.employee_id = r.employee_id and se.status = 'open') then
      insert into public.reminder_log (employee_id, day, kind) values (r.employee_id, r.day, 'check_out') on conflict do nothing;
      if found then
        perform private.notify(r.employee_id, r.company_id, 'reminder_check_out', 'تذكير بتسجيل الانصراف',
          case when r.check_out_before = 0 then 'انتهى دوامك الآن (' else 'ينتهي دوامك الساعة ' end
            || to_char(r.shift_end at time zone r.timezone, 'HH24:MI')
            || case when r.check_out_before = 0 then '). ' else '. ' end || 'لا تنسَ تسجيل الانصراف.',
          './', 'reminder-out', 900);
        v_count := v_count + 1;
      end if;
    end if;
  end loop;

  delete from public.reminder_log where day < (p_now at time zone 'UTC')::date - 7;
  delete from public.notifications where created_at < p_now - interval '30 days';
  return v_count;
end;
$$;
revoke all on function private.enqueue_due_reminders(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------- 5. Employee: devices and settings
create or replace function public.employee_save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
begin
  select * into me from public.require_active_employee();
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or p_p256dh is null or length(p_p256dh) not between 80 and 100 or p_auth is null or length(p_auth) not between 16 and 30 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  -- The same phone used by another account before: the device now belongs to me.
  insert into public.push_subscriptions (user_id, company_id, endpoint, p256dh, auth, user_agent)
  values (me.employee_id, me.company_id, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, company_id = excluded.company_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, fail_count = 0;
  insert into public.notification_settings (employee_id, company_id) values (me.employee_id, me.company_id)
  on conflict (employee_id) do nothing;
end;
$$;

create or replace function public.employee_delete_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
begin
  select * into me from public.require_active_employee();
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = me.employee_id;
end;
$$;

create or replace function public.employee_get_notification_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public'
as $$
declare
  me record;
  s public.notification_settings;
begin
  select * into me from public.require_active_employee();
  select * into s from public.notification_settings where employee_id = me.employee_id;
  return jsonb_build_object(
    'remind_check_in', coalesce(s.remind_check_in, false),
    'check_in_before', coalesce(s.check_in_before, 10),
    'remind_check_out', coalesce(s.remind_check_out, false),
    'check_out_before', coalesce(s.check_out_before, 0),
    'devices', (select count(*) from public.push_subscriptions p where p.user_id = me.employee_id));
end;
$$;

create or replace function public.employee_set_notification_settings(
  p_remind_check_in boolean, p_check_in_before integer, p_remind_check_out boolean, p_check_out_before integer
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
begin
  select * into me from public.require_active_employee();
  if p_remind_check_in is null or p_remind_check_out is null
     or p_check_in_before is null or p_check_in_before not between 0 and 120
     or p_check_out_before is null or p_check_out_before not between 0 and 120 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  insert into public.notification_settings (employee_id, company_id, remind_check_in, check_in_before, remind_check_out, check_out_before, updated_at)
  values (me.employee_id, me.company_id, p_remind_check_in, p_check_in_before, p_remind_check_out, p_check_out_before, now())
  on conflict (employee_id) do update
    set remind_check_in = excluded.remind_check_in, check_in_before = excluded.check_in_before,
        remind_check_out = excluded.remind_check_out, check_out_before = excluded.check_out_before, updated_at = now();
  return public.employee_get_notification_settings();
end;
$$;

-- A test notification to my own devices (at most one every 30 seconds).
create or replace function public.employee_test_notification()
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me record;
begin
  select * into me from public.require_active_employee();
  if not exists (select 1 from public.push_subscriptions where user_id = me.employee_id) then
    raise exception 'no_device' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.notifications where user_id = me.employee_id and kind = 'test' and created_at > now() - interval '30 seconds') then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  perform private.notify(me.employee_id, me.company_id, 'test', 'وقتي', 'الإشعارات تعمل على هذا الجهاز.', './', 'test', 600);
end;
$$;

-- ---------------------------------------------------------------- 6. Sender (Edge Function, service role only)
-- Claims up to p_limit unsent notifications with the devices of each recipient. A claim expires after
-- 2 minutes (a crashed sender does not lose them); at most 5 attempts.
create or replace function public.push_claim_batch(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_ids bigint[];
begin
  select array_agg(id) into v_ids from (
    select n.id from public.notifications n
    where n.sent_at is null and n.attempts < 5
      and (n.claimed_at is null or n.claimed_at < now() - interval '2 minutes')
      and n.created_at > now() - make_interval(secs => n.ttl_seconds)
    order by n.created_at
    limit greatest(least(coalesce(p_limit, 50), 200), 1)
    for update skip locked) x;
  if v_ids is null then
    return '[]'::jsonb;
  end if;
  update public.notifications set claimed_at = now(), attempts = attempts + 1 where id = any (v_ids);
  return (
    select jsonb_agg(jsonb_build_object(
             'id', n.id, 'title', n.title, 'body', n.body, 'url', n.url, 'tag', n.tag, 'kind', n.kind,
             'ttl', greatest(60, n.ttl_seconds - extract(epoch from now() - n.created_at)::int),
             'subscriptions', coalesce((select jsonb_agg(jsonb_build_object('endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth))
                                        from public.push_subscriptions p where p.user_id = n.user_id), '[]'::jsonb))
           order by n.created_at)
    from public.notifications n where n.id = any (v_ids));
end;
$$;

-- p_results: [{"id": 1, "ok": true, "error": null, "gone": ["https://..."], "delivered": ["https://..."]}]
create or replace function public.push_report(p_results jsonb)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  x jsonb;
begin
  for x in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    update public.notifications
       set sent_at = case when (x ->> 'ok')::boolean then now() end,
           claimed_at = case when (x ->> 'ok')::boolean then claimed_at end,
           last_error = left(x ->> 'error', 300)
     where id = (x ->> 'id')::bigint;
    delete from public.push_subscriptions where endpoint in (select jsonb_array_elements_text(coalesce(x -> 'gone', '[]'::jsonb)));
    update public.push_subscriptions set last_success_at = now(), fail_count = 0
     where endpoint in (select jsonb_array_elements_text(coalesce(x -> 'delivered', '[]'::jsonb)));
  end loop;
end;
$$;

-- ---------------------------------------------------------------- 7. Grants
do $g$
declare f text;
begin
  foreach f in array array[
    'public.employee_save_push_subscription(text, text, text, text)',
    'public.employee_delete_push_subscription(text)',
    'public.employee_get_notification_settings()',
    'public.employee_set_notification_settings(boolean, integer, boolean, integer)',
    'public.employee_test_notification()'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.push_claim_batch(integer)', 'public.push_report(jsonb)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end
$g$;
