// Company calendar (phase 16e): the name of the weekly day off, official holidays, today's holiday.
// A copy is kept per account so the labels are right with no connection. Nothing here throws.
export interface Calendar {
  weekly_off_label: string | null;
  holidays: { name: string; start_date: string; end_date: string; repeats_yearly?: boolean; cancelled?: boolean }[];
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

export interface HolidayItem { name: string; when: string; note: string | null; cancelled: boolean }

const dm = (iso: string) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}`;
function nextDay(iso: string): string {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Official holidays for the Home card: every one still to come (or going on today), cancelled ones included, sorted by
 * date. `today` is the company's date (YYYY-MM-DD). A holiday disappears once its last day has passed.
 */
export function holidayItems(c: Calendar | null, today: string): HolidayItem[] {
  return (c?.holidays ?? [])
    .filter((h) => h.end_date >= today)
    .sort((a, b) => a.start_date.localeCompare(b.start_date))
    .map((h) => ({
      name: h.name,
      when: h.start_date <= today ? "اليوم" : h.start_date === nextDay(today) && h.end_date === h.start_date ? "غدًا"
        : h.end_date === h.start_date ? dm(h.start_date) : `${dm(h.start_date)} – ${dm(h.end_date)}`,
      note: h.cancelled ? "أُلغيت — الدوام كالمعتاد" : h.repeats_yearly ? "كل سنة" : null,
      cancelled: !!h.cancelled,
    }));
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
