-- ============================================================================
-- Waqti Phase 5b: send the notifications (production only: needs pg_cron and pg_net).
--   * Right after notifications are queued, the database calls the send-push Edge Function (pg_net).
--   * Every minute (pg_cron): queue the due attendance reminders, and call send-push again if anything
--     is still unsent (retries).
--   * The Edge Function checks a shared secret (header x-waqti-cron). The secret is stored in
--     private.app_secrets ('push_cron_secret') and as the function secret WAQTI_CRON_SECRET.
--     It is set OUTSIDE this file (never in the repository). Without it, nothing is called.
-- ============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function private.push_kick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  select convert_from(value, 'UTF8') into v_secret from private.app_secrets where name = 'push_cron_secret';
  if v_secret is null then
    return;
  end if;
  perform net.http_post(
    url := 'https://fgnbdlqmtezneznwvahf.supabase.co/functions/v1/send-push',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-waqti-cron', v_secret),
    timeout_milliseconds := 30000);
end;
$$;
revoke all on function private.push_kick() from public, anon, authenticated;

-- New notifications: send at once (one call per statement, after commit).
create or replace function private.on_notifications_inserted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.push_kick();
  return null;
end;
$$;
revoke all on function private.on_notifications_inserted() from public, anon, authenticated;
create trigger notifications_kick after insert on public.notifications
  for each statement execute function private.on_notifications_inserted();

-- Every minute: reminders, then retries.
create or replace function private.push_tick()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.enqueue_due_reminders(now());
  if exists (select 1 from public.notifications n
             where n.sent_at is null and n.attempts < 5
               and (n.claimed_at is null or n.claimed_at < now() - interval '2 minutes')
               and n.created_at > now() - make_interval(secs => n.ttl_seconds)) then
    perform private.push_kick();
  end if;
end;
$$;
revoke all on function private.push_tick() from public, anon, authenticated;

select cron.schedule('waqti-push-tick', '* * * * *', 'select private.push_tick()');
