// "My data summary" on the profile: what to draw from the server's (already filtered) summary. Pure, unit-tested.
import { LEAVE_LABEL } from "./requests";
import type { LeaveType, ProfileSummary } from "./types";

/** Arabic count with the right form: 1 سنة, 2 سنتان, 3-10 سنوات, 11+ سنة. */
function count(n: number, one: string, two: string, few: string, many: string): string {
  if (n === 1) return one;
  if (n === 2) return two;
  return `${n} ${n <= 10 ? few : many}`;
}

/** Time since hiring: "4 سنوات و 8 أشهر". Under a month: "أقل من شهر". A future or bad date: null. */
export function serviceLength(hireDate: string, today: Date = new Date()): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(hireDate);
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  let months = (today.getFullYear() - y) * 12 + (today.getMonth() + 1 - mo);
  if (today.getDate() < d) months -= 1;
  if (months < 0 || new Date(y, mo - 1, d) > today) return null;
  if (months === 0) return "أقل من شهر";
  const years = Math.floor(months / 12);
  const rest = months % 12;
  const ys = years ? count(years, "سنة", "سنتان", "سنوات", "سنة") : "";
  const ms = rest ? count(rest, "شهر", "شهران", "أشهر", "شهرًا") : "";
  if (ys && ms) return /^\d/.test(ms) ? `${ys} و ${ms}` : `${ys} و${ms}`;
  return ys || ms;
}

const DAY = ["الأحد", "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"]; // PostgreSQL dow: 0 = Sunday
const WEEK = [6, 0, 1, 2, 3, 4, 5]; // Libyan week: Saturday first

/** Following days with the same hours become one line: "السبت – الأربعاء" 08:00–16:00. */
export function groupSchedule(rows: NonNullable<ProfileSummary["schedule"]>): { days: string; hours: string }[] {
  const byDay = new Map(rows.map((r) => [r.weekday, r]));
  const out: { days: string; hours: string; first: number; last: number }[] = [];
  for (const d of WEEK) {
    const r = byDay.get(d);
    if (!r) continue;
    const hours = r.is_workday && r.start_time && r.end_time ? `${r.start_time}–${r.end_time}` : "إجازة";
    const prev = out[out.length - 1];
    if (prev && prev.hours === hours && WEEK.indexOf(prev.last) + 1 === WEEK.indexOf(d)) prev.last = d;
    else out.push({ days: "", hours, first: d, last: d });
  }
  return out.map((g) => ({ days: g.first === g.last ? DAY[g.first] : `${DAY[g.first]} – ${DAY[g.last]}`, hours: g.hours }));
}

/** LYD: "1,750.5 د.ل" (Latin digits, like the rest of the app). */
export function money(n: number): string {
  return `${n.toLocaleString("en-US", { maximumFractionDigits: 3 })} د.ل`;
}

const days = (n: number) => (n === 1 ? "يوم" : n === 2 ? "يومان" : n >= 3 && n <= 10 && Number.isInteger(n) ? `${n} أيام` : `${n} يومًا`);

export interface SummaryRow { label: string; value: string; note?: string; ltr?: boolean; strong?: boolean }
export interface SummaryGroup { title: string; rows: SummaryRow[] }

/** The groups to draw. Rows without a value are dropped; a group without rows is dropped. */
export function summaryGroups(s: ProfileSummary, today: Date = new Date()): SummaryGroup[] {
  const e = s.employee ?? {};
  const job: SummaryRow[] = [];
  if (e.department) job.push({ label: "القسم", value: e.department });
  if (e.job_title) job.push({ label: "المسمى الوظيفي", value: e.job_title });
  if (e.work_location_name) job.push({ label: "موقع العمل", value: e.work_location_name });
  if (e.hire_date) {
    const since = serviceLength(e.hire_date, today);
    job.push({ label: "تاريخ التعيين", value: e.hire_date, ...(since ? { note: since } : {}), ltr: true });
  }
  const work: SummaryRow[] = groupSchedule(s.schedule ?? []).map((g) => ({ label: g.days, value: g.hours, ltr: g.hours !== "إجازة" }));
  const leave: SummaryRow[] = (s.leave ?? []).map((l) => ({ label: LEAVE_LABEL[l.type as LeaveType] ?? l.type, value: days(l.days) }));
  const pay: SummaryRow[] = [];
  if (s.salary?.base_salary !== undefined) pay.push({ label: "الراتب الأساسي", value: money(s.salary.base_salary), ltr: true });
  for (const c of s.salary?.components ?? []) pay.push({ label: c.name, value: money(c.amount), ltr: true });
  if (s.salary?.total !== undefined) pay.push({ label: "إجمالي الراتب", value: money(s.salary.total), ltr: true, strong: true });
  const me: SummaryRow[] = [];
  if (e.birth_date) me.push({ label: "تاريخ الميلاد", value: e.birth_date, ltr: true });
  if (e.gender === "male" || e.gender === "female") me.push({ label: "الجنس", value: e.gender === "male" ? "ذكر" : "أنثى" });
  return [
    { title: "الوظيفة", rows: job },
    { title: "الدوام", rows: work },
    { title: "الإجازات", rows: leave },
    { title: "الراتب", rows: pay },
    { title: "شخصي", rows: me },
  ].filter((g) => g.rows.length > 0);
}

// ---- a copy on this phone: shown at once and with no connection; replaced every time the profile opens online.
type Store = Pick<Storage, "getItem" | "setItem">;
const KEY = (userId: string) => `waqti-summary:${userId}`;
function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}
export function saveSummary(userId: string, data: ProfileSummary, now = Date.now(), store: Store | null = defaultStore()): void {
  try {
    store?.setItem(KEY(userId), JSON.stringify({ data, saved_at_ms: now }));
  } catch {
    /* blocked or full storage: the profile just needs the internet */
  }
}
export function loadSummary(userId: string, store: Store | null = defaultStore()): { data: ProfileSummary; saved_at_ms: number } | null {
  try {
    const raw = store?.getItem(KEY(userId));
    if (!raw) return null;
    const v = JSON.parse(raw) as { data?: unknown; saved_at_ms?: unknown };
    return v && typeof v.data === "object" && v.data !== null && typeof v.saved_at_ms === "number"
      ? { data: v.data as ProfileSummary, saved_at_ms: v.saved_at_ms }
      : null;
  } catch {
    return null;
  }
}
