// Overtime screen logic (pure, unit-tested). The server decides everything (team, shift, limits).
import type { AppErrorCode } from "./errors";
import { formatMinutes, localDate, localTime, zonedToUtc } from "./requests";
import type { OvertimeInput, OvertimeItem, OvertimePreview } from "./types";

export interface OvertimeDraft {
  employee_id: string;
  date: string;
  from: string;
  to: string;
  task: string;
}

export const emptyOvertimeDraft = (today: string, employeeId = ""): OvertimeDraft => ({ employee_id: employeeId, date: today, from: "", to: "", task: "" });

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^\d{2}:\d{2}$/;

/** The form as an assignment, or why it is not complete yet (null = just not filled in). */
export function overtimeInput(d: OvertimeDraft, timeZone: string): { ok: true; input: OvertimeInput } | { ok: false; error: AppErrorCode | null } {
  if (!d.employee_id || !d.from || !d.to) return { ok: false, error: null };
  if (!DATE.test(d.date) || !TIME.test(d.from) || !TIME.test(d.to) || d.to <= d.from) return { ok: false, error: "invalid_dates" };
  const task = d.task.trim() === "" ? null : d.task.trim();
  if (task !== null && task.length > 500) return { ok: false, error: "invalid_input" };
  return { ok: true, input: { employee_id: d.employee_id, start_at: zonedToUtc(d.date, d.from, timeZone), end_at: zonedToUtc(d.date, d.to, timeZone), task } };
}

/** After "من": "ساعتين" not "ساعتان". */
const ofMinutes = (m: number) => formatMinutes(m).replace(/^ساعتان/, "ساعتين");

export const overtimeSignature = (i: OvertimeInput) => JSON.stringify({ ...i, task: null });

/** "18:00–20:00" in the company time zone. */
export const overtimeHours = (o: Pick<OvertimeItem, "start_at" | "end_at">, timeZone: string) =>
  `${localTime(o.start_at, timeZone)}–${localTime(o.end_at, timeZone)}`;

/** Limits after this assignment, e.g. "اليوم: ساعتان من 3 ساعات · الشهر: 5 ساعات من 20 ساعة". */
export function limitsLine(p: OvertimePreview): string {
  const part = (label: string, used: number, limit: number | null) =>
    limit === null ? `${label}: ${formatMinutes(used + p.minutes)} (بلا حد)` : `${label}: ${formatMinutes(used + p.minutes)} من ${ofMinutes(limit)}`;
  return `${part("اليوم", p.used_day, p.limit_day)} · ${part("الشهر", p.used_month, p.limit_month)}`;
}

/** The employee's shift that day, so the manager sees why a time is refused. */
export function shiftLine(p: OvertimePreview, timeZone: string): string {
  return p.shift_start && p.shift_end
    ? `دوامه هذا اليوم \u2066${localTime(p.shift_start, timeZone)}–${localTime(p.shift_end, timeZone)}\u2069` // LTR isolate: hours never flip
    : "هذا اليوم عطلته";
}

/** Assigned vs worked, e.g. "عمل ساعة و35 د من ساعتين". */
export function actualLine(o: Pick<OvertimeItem, "phase" | "minutes" | "actual_minutes">): string | null {
  if (o.phase === "upcoming" || o.phase === "cancelled" || o.actual_minutes === null) return null;
  if (o.actual_minutes === 0) return o.phase === "now" ? "لم يسجّل حضوره بعد" : "لم يسجّل حضورًا في وقت التكليف";
  return `${o.phase === "now" ? "حتى الآن" : "عمل"} ${formatMinutes(o.actual_minutes)} من ${ofMinutes(o.minutes)}`;
}

export const PHASE_LABEL: Record<OvertimeItem["phase"], string> = {
  upcoming: "قادم",
  now: "جارٍ الآن",
  done: "انتهى",
  cancelled: "ملغى",
};

/** Upcoming and running first (soonest first), then the past (latest first). */
export function sortOvertime(items: OvertimeItem[]): OvertimeItem[] {
  const live = (o: OvertimeItem) => o.phase === "upcoming" || o.phase === "now";
  return [...items].sort((a, b) => {
    if (live(a) !== live(b)) return live(a) ? -1 : 1;
    return live(a) ? a.start_at.localeCompare(b.start_at) : b.start_at.localeCompare(a.start_at);
  });
}

export const overtimeDay = (o: Pick<OvertimeItem, "start_at">, timeZone: string) => localDate(o.start_at, timeZone);
