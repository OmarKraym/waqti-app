// Turns the event list into what the employee thinks in: today's card, and one row per earlier day.
// Pure functions (no DOM), unit-tested.

import { isQueuedEvent } from "./offlineQueue";
import type { AttendanceAction, AttendanceEvent } from "./types";

/** Calendar day of an instant in the company's time zone, as YYYY-MM-DD. */
export function dayKey(iso: string | number, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
}

export type SlotKind = "stamped" | "pencil" | "empty";

export interface CardRow {
  key: string;
  action: AttendanceAction;
  kind: SlotKind;
  /** ISO time, absent for an empty slot. */
  time?: string;
  needsReview?: boolean;
  /** Phase 20: the admin added this movement. Never true for an empty slot or a punch still waiting on the phone. */
  byAdmin: boolean;
  event?: AttendanceEvent;
}

/**
 * Rows of today's time card, oldest first.
 * - every event of today (stamped when the server confirmed it, pencil when it waits on the phone)
 * - an open session that started on an earlier day is shown too (night shift)
 * - then an empty slot for what comes next (none after a check-out)
 */
export function todayRows(
  events: AttendanceEvent[],
  openSessionStart: string | null,
  nowMs: number,
  timeZone: string,
): CardRow[] {
  const today = dayKey(nowMs, timeZone);
  const own = events
    .filter((e) => dayKey(e.server_time, timeZone) === today || (openSessionStart !== null && e.server_time === openSessionStart))
    .slice()
    .sort((a, b) => Date.parse(a.server_time) - Date.parse(b.server_time));

  const rows: CardRow[] = own.map((e) => ({
    key: e.id,
    action: e.action,
    kind: isQueuedEvent(e) ? "pencil" : "stamped",
    time: e.server_time,
    needsReview: e.needs_review,
    byAdmin: e.by_admin === true && !isQueuedEvent(e),
    event: e,
  }));

  if (rows.length === 0) {
    return [
      { key: "slot-in", action: "check_in", kind: "empty", byAdmin: false },
      { key: "slot-out", action: "check_out", kind: "empty", byAdmin: false },
    ];
  }
  if (rows[rows.length - 1].action === "check_in") rows.push({ key: "slot-out", action: "check_out", kind: "empty", byAdmin: false });
  return rows;
}

export interface DayRow {
  day: string; // YYYY-MM-DD
  firstIn?: string;
  lastOut?: string;
  /** Minutes worked in complete in/out pairs of that day. */
  minutes: number;
  /** A check-in without its check-out on that day. */
  open: boolean;
  needsReview: boolean;
  /** Phase 20: the admin added at least one movement of that day. */
  byAdmin: boolean;
}

/** One row per earlier day (newest first), from the events the app has. Today is excluded. */
export function earlierDays(events: AttendanceEvent[], nowMs: number, timeZone: string, max = 5): DayRow[] {
  const today = dayKey(nowMs, timeZone);
  const byDay = new Map<string, AttendanceEvent[]>();
  for (const e of events) {
    const d = dayKey(e.server_time, timeZone);
    if (d === today) continue;
    byDay.set(d, [...(byDay.get(d) ?? []), e]);
  }
  const rows: DayRow[] = [];
  for (const [day, list] of byDay) {
    const sorted = list.slice().sort((a, b) => Date.parse(a.server_time) - Date.parse(b.server_time));
    let minutes = 0;
    let openIn: string | null = null;
    for (const e of sorted) {
      if (e.action === "check_in") openIn = e.server_time;
      else if (openIn) {
        minutes += Math.round((Date.parse(e.server_time) - Date.parse(openIn)) / 60_000);
        openIn = null;
      }
    }
    rows.push({
      day,
      firstIn: sorted.find((e) => e.action === "check_in")?.server_time,
      lastOut: [...sorted].reverse().find((e) => e.action === "check_out")?.server_time,
      minutes,
      open: openIn !== null,
      needsReview: sorted.some((e) => e.needs_review),
      byAdmin: sorted.some((e) => e.by_admin === true),
    });
  }
  return rows.sort((a, b) => (a.day < b.day ? 1 : -1)).slice(0, max);
}

/**
 * Minutes worked on today's card: confirmed (stamped) in/out pairs, plus the open session until now.
 * Punches still waiting on the phone (pencil) count for nothing until the server confirms them.
 */
export function workedToday(rows: CardRow[], openSessionStart: string | null, nowMs: number): number {
  let ms = 0;
  let openIn: string | null = null;
  for (const r of rows) {
    if (r.kind !== "stamped" || !r.time) continue;
    if (r.action === "check_in") openIn = r.time;
    else if (openIn) {
      ms += Date.parse(r.time) - Date.parse(openIn);
      openIn = null;
    }
  }
  if (openSessionStart && openIn === openSessionStart) ms += Math.max(0, nowMs - Date.parse(openSessionStart));
  return Math.floor(ms / 60_000);
}

/** "8 س 05 د" — hours and minutes, Western digits. */
export function formatDuration(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h > 0 ? `${h} س ${String(m).padStart(2, "0")} د` : `${m} د`;
}
