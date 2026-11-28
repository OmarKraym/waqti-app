// The attendance log of a period the employee picks (from – to). Pure functions, unit-tested.
import { addDays, formatDays } from "./requests";
import { formatDuration, type DayRow } from "./timecard";

/** Longest period one request may cover (about three months), so the list and the request stay small. */
export const MAX_HISTORY_DAYS = 92;

/** The period the window opens on: the last 30 days, up to yesterday (today has its own card on Home). */
export function defaultRange(today: string): { from: string; to: string } {
  return { from: addDays(today, -30), to: addDays(today, -1) };
}

/** null when the period can be shown, else the one line that says what to fix. Dates are YYYY-MM-DD. */
export function checkRange(from: string, to: string, today: string): string | null {
  if (!from || !to) return "اختر التاريخين.";
  if (from > to) return "تاريخ البداية بعد تاريخ النهاية.";
  if (to > today) return "لا يمكن اختيار يوم بعد اليوم.";
  const days = Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1;
  if (days > MAX_HISTORY_DAYS) return `أقصى مدة ${MAX_HISTORY_DAYS} يومًا. اختر فترة أقصر.`;
  return null;
}

/** The UTC window asked from the server: one day wider on each side, whatever the company's time zone. */
export function queryWindow(from: string, to: string): { fromIso: string; toIso: string } {
  return { fromIso: `${addDays(from, -1)}T00:00:00.000Z`, toIso: `${addDays(to, 2)}T00:00:00.000Z` };
}

/** «3 أيام حضور · المجموع 15 س 30 د» above the list. */
export function historySummary(days: DayRow[]): string {
  if (days.length === 0) return "لا توجد حركات في هذه الفترة.";
  const minutes = days.reduce((s, d) => s + d.minutes, 0);
  return `${formatDays(days.length)} حضور · المجموع ${formatDuration(minutes)}`;
}
