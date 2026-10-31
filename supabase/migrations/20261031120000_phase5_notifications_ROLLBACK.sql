-- ROLLBACK for 20261031120000_phase5_notifications.sql
-- DATA LOSS: devices, reminder settings and queued/sent notifications are deleted.
-- (Roll back 20261031130000_phase5b_push_schedule.sql first.)
drop trigger if exists request_approvals_notify on public.request_approvals;
drop trigger if exists requests_notify_decision on public.requests;
drop function if exists public.push_report(jsonb);
drop function if exists public.push_claim_batch(integer);
drop function if exists public.employee_test_notification();
drop function if exists public.employee_set_notification_settings(boolean, integer, boolean, integer);
drop function if exists public.employee_get_notification_settings();
drop function if exists public.employee_delete_push_subscription(text);
drop function if exists public.employee_save_push_subscription(text, text, text, text);
drop function if exists private.enqueue_due_reminders(timestamptz);
drop function if exists private.on_request_decided();
drop function if exists private.on_approval_pending();
drop function if exists private.request_summary(uuid);
drop function if exists private.days_text(numeric);
drop function if exists private.notify(uuid, uuid, text, text, text, text, text, integer);
drop table if exists public.reminder_log;
drop table if exists public.notifications;
drop table if exists public.notification_settings;
drop table if exists public.push_subscriptions;
