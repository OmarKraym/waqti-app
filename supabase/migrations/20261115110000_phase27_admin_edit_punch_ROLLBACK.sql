-- Rollback of phase 27: removes the function. Movements that were edited keep their new times (nothing is put back):
-- the time before the first edit is in each movement's metadata (original_occurred_at, edits) and in the audit log ('attendance.edit_time').
drop function if exists public.admin_edit_punch(uuid, timestamp with time zone, text);
