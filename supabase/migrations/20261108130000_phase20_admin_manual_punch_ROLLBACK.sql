-- Rollback of phase 20 (20261108130000_phase20_admin_manual_punch.sql).
-- Removes the function only. The events and sessions it already created stay: they are attendance history
-- (source 'admin_manual' in the event's metadata, 'attendance.manual_add' in the audit log), and nothing here deletes history.
drop function if exists public.admin_add_punch(uuid, text, timestamp with time zone, text);
