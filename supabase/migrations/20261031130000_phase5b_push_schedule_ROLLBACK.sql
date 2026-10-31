-- ROLLBACK for 20261031130000_phase5b_push_schedule.sql (stops sending; the queue stays).
select cron.unschedule('waqti-push-tick') where exists (select 1 from cron.job where jobname = 'waqti-push-tick');
drop trigger if exists notifications_kick on public.notifications;
drop function if exists private.push_tick();
drop function if exists private.on_notifications_inserted();
drop function if exists private.push_kick();
drop function if exists public.push_config();
delete from private.app_secrets where name in ('push_cron_secret', 'vapid_private_jwk');
