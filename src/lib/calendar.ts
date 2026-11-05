// Company calendar (phase 16e): the name of the weekly day off, official holidays, today's holiday.
// A copy is kept per account so the labels are right with no connection. Nothing here throws.
export interface Calendar {
  weekly_off_label: string | null;
  holidays: CalendarDay[];
  today_holiday: string | null;
}

/** An official holiday, or (phase 18b) days the administration made annual leave, with the rules it picked. */
export interface CalendarDay {
  kind?: "holiday" | "annual_leave";
  name: string;
  start_date: string;
  end_date: string;
  repeats_yearly?: boolean;
  cancelled?: boolean;
  scope?: "absent" | "all";
  worked_rule?: "no_deduct" | "deduct" | "deduct_overtime";
  short_rule?: "negative" | "unpaid";
}

/** What the app calls the weekly day off (the company's text; "عطلة" until it is known). */
export function offLabel(c: Calendar | null): string {
  return c?.weekly_off_label?.trim() || "عطلة";
}

/** The line on Home when today is an official holiday. */
export function holidayBanner(c: Calendar | null): string | null {
  return c?.today_holiday ? `اليوم عطلة رسمية: ${c.today_holiday}` : null;
}

export interface HolidayItem { name: string; when: string; note: string | null; cancelled: boolean; kind: "holiday" | "annual_leave" }

/** The rules of an administration leave day, in one line. */
function leaveDayNote(h: CalendarDay): string {
  if (h.scope !== "all") return "إجازة سنوية لمن لا يحضر ولا يبصم (تُخصم من رصيده)";
  const worked = h.worked_rule === "deduct" ? "تُخصم حتى لمن يحضر"
    : h.worked_rule === "deduct_overtime" ? "من يحضر يُحسب وقته عملًا إضافيًا" : "من يحضر ويبصم لا تُخصم منه";
  return ["إجازة سنوية للجميع (تُخصم من الرصيد)", worked, h.short_rule === "unpaid" ? "إن لم يكفِ رصيدك: بدون راتب" : null]
    .filter(Boolean).join(" · ");
}

const dmy = (iso: string) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;
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
      when: (h.start_date <= today ? "اليوم · " : h.start_date === nextDay(today) ? "غدًا · " : "")
        + (h.end_date === h.start_date ? dmy(h.start_date) : `${dmy(h.start_date)} – ${dmy(h.end_date)}`),
      note: h.cancelled ? "أُلغيت — الدوام كالمعتاد" : h.kind === "annual_leave" ? leaveDayNote(h) : h.repeats_yearly ? "كل سنة" : null,
      cancelled: !!h.cancelled,
      kind: h.kind ?? "holiday",
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
