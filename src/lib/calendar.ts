// Company calendar (phase 16e): the name of the weekly day off, official holidays, today's holiday.
// A copy is kept per account so the labels are right with no connection. Nothing here throws.
export interface Calendar {
  weekly_off_label: string | null;
  holidays: { name: string; start_date: string; end_date: string }[];
  today_holiday: string | null;
}

/** What the app calls the weekly day off (the company's text; "عطلة" until it is known). */
export function offLabel(c: Calendar | null): string {
  return c?.weekly_off_label?.trim() || "عطلة";
}

/** The line on Home when today is an official holiday. */
export function holidayBanner(c: Calendar | null): string | null {
  return c?.today_holiday ? `اليوم عطلة رسمية: ${c.today_holiday}` : null;
}

type Store = Pick<Storage, "getItem" | "setItem">;
const KEY = (userId: string) => `waqti-calendar:${userId}`;
function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}
export function saveCalendar(userId: string, c: Calendar, store: Store | null = defaultStore()): void {
  try {
    store?.setItem(KEY(userId), JSON.stringify(c));
  } catch {
    /* not critical */
  }
}
export function loadCalendar(userId: string, store: Store | null = defaultStore()): Calendar | null {
  try {
    const raw = store?.getItem(KEY(userId));
    if (!raw) return null;
    const v = JSON.parse(raw) as Calendar;
    return v && Array.isArray(v.holidays) ? v : null;
  } catch {
    return null;
  }
}
