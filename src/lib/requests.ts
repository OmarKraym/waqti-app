// Requests screen logic: labels, dates in the company time zone, the form, approval progress.
// Pure functions (no DOM, no network), unit-tested. The SERVER decides everything (balance, limits,
// approvers); this file only shapes input and output.

import { format12, zonedHMS } from "./time12";
import type {
  ApprovalStep,
  ApproverKind,
  LeaveBalance,
  LeaveType,
  NewRequest,
  PermissionMode,
  PermissionUsage,
  RequestItem,
  RequestStatus,
  RequestType,
} from "./types";
import type { AppErrorCode } from "./errors";

export const TYPE_LABEL: Record<RequestType, string> = {
  leave: "إجازة",
  permission: "إذن",
  other: "طلب آخر",
};

export const LEAVE_LABEL: Record<LeaveType, string> = {
  annual: "سنوية",
  sick: "مرضية",
  emergency: "طارئة",
  marriage: "زواج",
  maternity: "أمومة",
  unpaid: "بدون راتب",
};

export const STATUS_LABEL: Record<RequestStatus, string> = {
  pending: "قيد الموافقة",
  approved: "مقبول",
  rejected: "مرفوض",
  cancelled: "ملغى",
};

export const KIND_LABEL: Record<ApproverKind, string> = {
  direct_manager: "المدير المباشر",
  second_manager: "مدير المدير",
  specific_employee: "موظف محدد",
  hr: "الموارد البشرية",
};

/** Full title of a request: "إجازة سنوية", "إذن: تبرير تأخير", "طلب آخر". */
export function requestTitle(r: Pick<RequestItem, "type" | "leave_type"> & { permission_type?: string | null }): string {
  if (r.type === "leave" && r.leave_type) return `إجازة ${LEAVE_LABEL[r.leave_type]}`;
  if (r.type === "permission" && r.permission_type) return `إذن: ${r.permission_type}`;
  return TYPE_LABEL[r.type];
}

// ---------------------------------------------------------------- dates in the company time zone

/** Offset (ms) of a time zone at an instant: local wall time minus UTC. */
function zoneOffsetMs(utcMs: number, timeZone: string): number {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    })
      .formatToParts(new Date(utcMs))
      .map((x) => [x.type, x.value]),
  );
  const wall = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  return wall - Math.floor(utcMs / 1000) * 1000;
}

/** "2026-11-03" + "10:30" on the wall clock of the company -> ISO instant (UTC). */
export function zonedToUtc(date: string, time: string, timeZone: string): string {
  const [y, mo, d] = date.split("-").map(Number);
  const [h, mi] = time.split(":").map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi);
  let utc = wall - zoneOffsetMs(wall, timeZone);
  utc = wall - zoneOffsetMs(utc, timeZone); // second pass: correct across a DST change
  return new Date(utc).toISOString();
}

/** YYYY-MM-DD of an instant in the company time zone. */
export function localDate(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
}

/** The time of an instant in the company time zone, as the employee reads it: "10:30 ص". */
export function localTime(iso: string, timeZone: string): string {
  const { h, m } = zonedHMS(iso, timeZone);
  return format12(h, m);
}

/** 24-hour "HH:MM" of an instant in the company time zone (the value of a time field, not for display). */
export function localHM(iso: string, timeZone: string): string {
  const { h, m } = zonedHMS(iso, timeZone);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

export function addDays(date: string, n: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

const dayFmt = (timeZone: string) =>
  new Intl.DateTimeFormat("ar-LY", { timeZone, weekday: "long", day: "numeric", month: "long", numberingSystem: "latn" });
const shortFmt = (timeZone: string) =>
  new Intl.DateTimeFormat("ar-LY", { timeZone, day: "numeric", month: "long", numberingSystem: "latn" });

/** A calendar date (YYYY-MM-DD) for display: "الثلاثاء 3 نوفمبر". */
export function formatDay(date: string): string {
  return dayFmt("UTC").format(new Date(`${date}T12:00:00Z`));
}

/**
 * When a request applies, as the employee reads it.
 *   leave / other:  "3 نوفمبر" or "3 نوفمبر – 5 نوفمبر"  (the stored end is exclusive)
 *   permission:     day + "10:00 – 12:00"
 */
export function formatPeriod(r: Pick<RequestItem, "type" | "start_at" | "end_at">, timeZone: string): { day: string; time: string | null } {
  if (r.type === "permission") {
    return { day: dayFmt(timeZone).format(new Date(r.start_at)), time: `${localTime(r.start_at, timeZone)} – ${localTime(r.end_at, timeZone)}` };
  }
  const first = localDate(r.start_at, timeZone);
  const last = addDays(localDate(r.end_at, timeZone), -1);
  const f = shortFmt("UTC");
  const a = f.format(new Date(`${first}T12:00:00Z`));
  return { day: first === last ? formatDay(first) : `${a} – ${f.format(new Date(`${last}T12:00:00Z`))}`, time: null };
}

/** "يوم واحد", "يومان", "3 أيام", "11 يومًا". Decimal days (half days) are shown as a number. */
export function formatDays(n: number): string {
  if (!Number.isInteger(n)) return `${n} يوم`;
  if (n === 1) return "يوم واحد";
  if (n === 2) return "يومان";
  if (n >= 3 && n <= 10) return `${n} أيام`;
  return `${n} يومًا`;
}

/** Minutes as hours: "ساعتان", "ساعة و30 د", "45 د". */
export function formatMinutes(min: number): string {
  const h = Math.floor(min / 60);
  const m = min % 60;
  const hours = h === 0 ? "" : h === 1 ? "ساعة" : h === 2 ? "ساعتان" : h <= 10 ? `${h} ساعات` : `${h} ساعة`;
  if (!hours) return `${m} د`;
  return m === 0 ? hours : `${hours} و${m} د`;
}

// ---------------------------------------------------------------- balances

/** What is left of a balance after a request of `days` (null = not limited). */
export function remainingAfter(b: LeaveBalance | null, days: number | null): number | null {
  if (!b || b.remaining === null || days === null) return null;
  return b.remaining - days;
}

/** Requests of this permission type still available this month (pending count); null = no limit. */
export function permissionLeft(p: PermissionUsage): number | null {
  return p.max_per_month === null ? null : Math.max(0, p.max_per_month - p.used - p.pending);
}

/** "مرة واحدة", "مرتان", "3 مرات", "11 مرة". */
export function formatTimes(n: number): string {
  if (n === 1) return "مرة واحدة";
  if (n === 2) return "مرتان";
  return n >= 3 && n <= 10 ? `${n} مرات` : `${n} مرة`;
}

// ---------------------------------------------------------------- approval progress

/** Steps the employee sees: skipped ones are hidden (they never needed anyone). */
export function visibleSteps(steps: ApprovalStep[]): ApprovalStep[] {
  return steps.filter((s) => s.status !== "skipped");
}

/** One line under a request: who has it now, or how it ended. */
export function progressLine(r: Pick<RequestItem, "status" | "steps">): string {
  const steps = visibleSteps(r.steps);
  if (r.status === "pending") {
    const at = steps.find((s) => s.status === "pending");
    if (!at) return "قيد الموافقة";
    const who = at.approver_name && at.kind !== "hr" ? `${KIND_LABEL[at.kind]} (${at.approver_name})` : KIND_LABEL[at.kind];
    return `بانتظار: ${who}`;
  }
  if (r.status === "rejected") {
    const by = steps.find((s) => s.status === "rejected");
    return by ? `رفضه: ${by.kind === "hr" ? KIND_LABEL.hr : (by.approver_name ?? KIND_LABEL[by.kind])}` : "مرفوض";
  }
  if (r.status === "approved") return "اكتملت الموافقات";
  return "ألغيته";
}

// ---------------------------------------------------------------- the form

export interface Draft {
  type: RequestType;
  leave_type: LeaveType;
  start_date: string;
  end_date: string;
  /** permission: its type, the day, and the times its mode needs (range: from+to, late: to, early: from) */
  permission_type_id: string;
  permission_mode: PermissionMode;
  date: string;
  from: string;
  to: string;
  reason: string;
}

export function emptyDraft(today: string, firstType?: Pick<PermissionUsage, "id" | "mode">): Draft {
  return {
    type: "leave", leave_type: "annual", start_date: today, end_date: today,
    permission_type_id: firstType?.id ?? "", permission_mode: firstType?.mode ?? "range",
    date: today, from: "", to: "", reason: "",
  };
}

/** The time fields a permission mode needs are filled in (nothing to complain about yet if not). */
export function permissionTimesFilled(d: Draft): boolean {
  if (d.permission_mode === "late_arrival") return d.to !== "";
  if (d.permission_mode === "early_leave") return d.from !== "";
  return d.from !== "" && d.to !== "";
}

/** The earliest day a leave may start. Without the company rule (older database) the server accepts up to 30 days back. */
export function leaveEarliest(o: { today: string; leave_earliest?: string }): string {
  return o.leave_earliest ?? addDays(o.today, -30);
}

/** A draft whose leave dates are not before the earliest allowed day (the end moves with the start). */
export function clampLeaveDates(d: Draft, earliest: string): Draft {
  if (d.type !== "leave" || d.start_date >= earliest) return d;
  return { ...d, start_date: earliest, end_date: d.end_date < earliest ? earliest : d.end_date };
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^\d{2}:\d{2}$/;

/**
 * The form as a request the server understands, or the reason it is not complete yet.
 * These are only the obvious checks (so the employee is told at once); the server re-checks everything.
 */
export function draftToRequest(d: Draft, timeZone: string): { ok: true; request: NewRequest } | { ok: false; error: AppErrorCode } {
  const reason = d.reason.trim() === "" ? null : d.reason.trim();
  if (reason !== null && reason.length > 500) return { ok: false, error: "invalid_input" };
  if (d.type === "permission") {
    if (!d.permission_type_id) return { ok: false, error: "permission_type_not_found" };
    if (!DATE.test(d.date)) return { ok: false, error: "invalid_dates" };
    const base = { type: "permission" as const, permission_type_id: d.permission_type_id, reason };
    if (d.permission_mode === "late_arrival") {
      if (!TIME.test(d.to)) return { ok: false, error: "invalid_dates" };
      return { ok: true, request: { ...base, start_at: null, end_at: zonedToUtc(d.date, d.to, timeZone) } };
    }
    if (d.permission_mode === "early_leave") {
      if (!TIME.test(d.from)) return { ok: false, error: "invalid_dates" };
      return { ok: true, request: { ...base, start_at: zonedToUtc(d.date, d.from, timeZone), end_at: null } };
    }
    if (!TIME.test(d.from) || !TIME.test(d.to) || d.to <= d.from) return { ok: false, error: "invalid_dates" };
    return { ok: true, request: { ...base, start_at: zonedToUtc(d.date, d.from, timeZone), end_at: zonedToUtc(d.date, d.to, timeZone) } };
  }
  if (!DATE.test(d.start_date) || !DATE.test(d.end_date) || d.end_date < d.start_date) return { ok: false, error: "invalid_dates" };
  if (d.type === "leave") {
    if (d.start_date.slice(0, 4) !== d.end_date.slice(0, 4)) return { ok: false, error: "crosses_year" };
    return { ok: true, request: { type: "leave", leave_type: d.leave_type, start_date: d.start_date, end_date: d.end_date, reason } };
  }
  if (reason === null) return { ok: false, error: "reason_required" };
  return { ok: true, request: { type: "other", start_date: d.start_date, end_date: d.end_date, reason } };
}

/** Same request = same preview: skips repeated preview calls while typing (the reason text does not matter). */
export function requestSignature(r: NewRequest): string {
  return JSON.stringify({ ...r, reason: r.reason ? 1 : 0 });
}
