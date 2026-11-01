-- Phase 8a (part 1): a session can end without a check-out ("missed_checkout").
-- Its own migration: Postgres cannot use a new enum value in the transaction that adds it.
-- Rollback: an enum value cannot be dropped; it is unused once 20261102090000 is rolled back.
alter type public.attendance_session_status add value if not exists 'missed_checkout';
