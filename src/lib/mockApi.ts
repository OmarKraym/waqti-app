// Fake server for UI work and demos (VITE_MOCK=1). Not used in production builds with VITE_MOCK=0.
// Behaves like the real contract, including idempotency and the location policies.
// Change the scenario from the URL, e.g. ?policy=geofence&outside=reject&pos=outside&net=flaky
//   policy = geofence | record | none        outside = flag | reject
//   pos    = inside | outside | far-accuracy  net     = ok | flaky (every 2nd punch loses its reply)
//   must_change = 1  (first login: forced password change)
//   history = 1      (adds three earlier work days, for screenshots)
//   inbox = 0        (no requests waiting for my approval; default: two, as a manager)
//   requests = 1     (adds sample requests of my own: approved, pending, rejected)
//   overtime = 1     (I manage a team of 3 and have one assignment of my own)
// With no connection (navigator.onLine === false) every call fails like a real network error.
// Offline punches are checked like the real server: signed-time token, clock consistency (+-120 s),
// one-sided monotonic check, 72 h limit, time order.

import type { SessionUser, WaqtiApi } from "./api";
import { newRequestId } from "./attendance";
import { AppError } from "./errors";
import { addDays, localDate } from "./requests";
import type {
  OvertimeInput,
  OvertimeItem,
  OvertimeOverview,
  OvertimePreview,
  TeamMember,
  AttendanceEvent,
  AttendanceState,
  InboxItem,
  LeaveBalance,
  LeaveType,
  LocationStatus,
  NewRequest,
  OfflinePunchInput,
  PermissionUsage,
  PunchInput,
  PunchResult,
  RequestItem,
  RequestPreview,
  ProfileSummary,
} from "./types";

const q = new URLSearchParams(globalThis.location?.search ?? "");
/** ?summary=default|all|none: what "My data summary" shows (default = the company defaults: no salary, no personal data). */
const summaryMode = q.get("summary") ?? "default";
const SUMMARY_FULL: Required<ProfileSummary> = {
  employee: { department: "المبيعات", job_title: "محاسب", work_location_name: "المقر الرئيسي", hire_date: "2022-03-01", birth_date: "1990-05-02", gender: "male" },
  schedule: [0, 1, 2, 3, 4, 5, 6].map((d) => (d === 5
    ? { weekday: d, is_workday: false, start_time: null, end_time: null }
    : { weekday: d, is_workday: true, start_time: "08:00", end_time: d === 4 ? "13:00" : "16:00" })),
  salary: { base_salary: 1500, components: [{ name: "بدل سكن", amount: 200 }, { name: "بدل نقل", amount: 50 }], total: 1750 },
  leave: [{ type: "annual", days: 30, is_default: true }, { type: "sick", days: 10, is_default: false }],
};
function mockSummary(): ProfileSummary {
  if (summaryMode === "all") return SUMMARY_FULL;
  if (summaryMode === "none") return {};
  const { birth_date: _b, gender: _g, ...job } = SUMMARY_FULL.employee;
  return { employee: job, schedule: SUMMARY_FULL.schedule, leave: SUMMARY_FULL.leave };
}
// ?leaveNotice=2 = a leave must start 2 days from today; ?leaveBack=3 = it may start 3 days back (default: from today)
const leaveNotice = Number(q.get("leaveNotice") ?? 0);
const leaveBack = Number(q.get("leaveBack") ?? 0);
const policy = (q.get("policy") ?? "geofence") as AttendanceState["location_policy"];
const outside = (q.get("outside") ?? "flag") as AttendanceState["outside_action"];
const pos = q.get("pos") ?? "inside";
const flaky = q.get("net") === "flaky";
/** ?bio=1: the company asks for the fingerprint and this account has a registered phone (the profile switch can be tried). */
const bio = q.get("bio") === "1" || q.get("bio") === "new";
/** ?bio=new: required, but this phone is not registered yet (the registration screen can be tried). */
const bioNew = q.get("bio") === "new";
/** ?forgot=1: no check-in yet, the check-in window is over and the check-out window is open (the button is "check out"). */
const forgotMode = q.get("forgot") === "1";
/** ?onleave=1: an approved leave covers today (the first punch is saved, flagged; the request list has a leave the manager cancelled). */
const onLeaveMode = q.get("onleave") === "1";
let leaveFlagged = false;
/** ?statefail=1: for 1.5 s after the new password is saved, reading the attendance state fails (the gate must stay closed). */
let stateFailUntil = 0;
const MAX_OFFLINE_MS = 72 * 3_600_000;
const TOLERANCE_MS = 120_000;

/** Stand-in for the server's signed token (the mock has nothing to protect). */
const tokenAt = (ms: number) => `mock.${ms}`;
const tokenTime = (t: string) => (/^mock\.\d+$/.test(t) ? Number(t.slice(5)) : null);

function requireNetwork(): void {
  if (globalThis.navigator && navigator.onLine === false) throw new AppError("network", "offline");
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** ?clock=2026-11-03T06:40:00Z starts the fake SERVER clock at that moment (tests: a late check-in at any real time). */
const clockStart = Date.parse(q.get("clock") ?? "");
const realNow = (): number =>
  globalThis.performance ? Math.round(performance.timeOrigin + performance.now()) : Date.now();
const clockShiftMs = Number.isNaN(clockStart) ? 0 : clockStart - realNow();

/** The fake SERVER clock: real time (or the ?clock= start), not affected when a test moves the phone clock (Date.now). */
const serverNow = (): number => realNow() + clockShiftMs;

export function createMockApi(): WaqtiApi {
  let user: SessionUser | null = null;
  try {
    const saved = localStorage.getItem("waqti-mock-user");
    if (saved) user = JSON.parse(saved);
  } catch {
    /* storage blocked: stay signed out */
  }
  const listeners = new Set<() => void>();
  const notify = () => listeners.forEach((l) => l());
  const save = () => {
    try {
      if (user) localStorage.setItem("waqti-mock-user", JSON.stringify(user));
      else localStorage.removeItem("waqti-mock-user");
    } catch {
      /* ignore */
    }
  };

  let loginEnabled = true;
  let hasDevice = !bioNew;
  const events: AttendanceEvent[] = [];
  if (q.get("history") === "1") {
    // Three earlier days (newest first), times in Tripoli = UTC+2.
    const day = (daysAgo: number, h: number, m: number) => {
      const d = new Date(serverNow());
      d.setUTCDate(d.getUTCDate() - daysAgo);
      d.setUTCHours(h - 2, m, 0, 0);
      return d.toISOString();
    };
    const add = (id: string, action: "check_in" | "check_out", iso: string, review = false) =>
      events.push({ id, action, server_time: iso, location_status: review ? "outside" : "inside", needs_review: review });
    add("h1o", "check_out", day(1, 16, 3)); add("h1i", "check_in", day(1, 8, 1));
    add("h2o", "check_out", day(2, 16, 10)); add("h2i", "check_in", day(2, 7, 58), true);
    add("h3o", "check_out", day(4, 15, 47)); add("h3i", "check_in", day(4, 8, 12));
  }
  const byRequest = new Map<string, PunchResult>();
  let punchCount = 0;

  const state = (): AttendanceState => {
    const last = events[0];
    const open = last?.action === "check_in";
    const forgot = forgotMode && !open && last?.action !== "check_out";
    return {
      employee: { full_name: "أحمد سالم", employee_number: "1024" },
      company: { name: "شركة تجريبية", timezone: "Africa/Tripoli" },
      next_action: open || forgot ? "check_out" : "check_in",
      can_check_out_without_in: !open && last?.action !== "check_out",
      forgot_check_in: forgot,
      open_session: open ? { started_at: last.server_time } : null,
      location_policy: policy,
      outside_action: outside,
      max_accuracy_m: 100,
      recent_events: events.slice(0, 10),
      server_time: new Date(serverNow()).toISOString(),
      time_token: tokenAt(serverNow()),
      // The fake server has no punch windows and no fingerprint (both are off by default on the real one too).
      punch_window: forgotMode && !forgot && !open
        ? { allowed: false, opens_at: null, closes_at: null, reason: "too_late" }
        : { allowed: true, opens_at: null, closes_at: null, reason: "no_limits" },
      biometric: bio ? { policy: "required", has_device: hasDevice, login_enabled: loginEnabled } : { policy: "off", has_device: false },
    };
  };

  /** Same decision logic for online (time = now) and offline (time = verified claimed time). */
  function record(input: PunchInput, timeMs: number, offline: boolean): PunchResult {
    const known = byRequest.get(input.request_id);
    if (known) return { ...known, duplicate: true, time_token: tokenAt(serverNow()) };
    if (events[0] && timeMs <= Date.parse(events[0].server_time)) throw new AppError("time_order");

    const s = state();
    // Phase 13: a check-out is also accepted when there is no check-in (he forgot it), once, if the last punch is not a check-out.
    const orphan = input.expected_action === "check_out" && !s.open_session && !!s.can_check_out_without_in;
    if (input.expected_action !== s.next_action && !orphan) throw new AppError("state_changed");

    const r = input.reading;
    let status: LocationStatus;
    let review = false;
    // Phase 15: a punch on an approved-leave day is saved; only the first one of the day goes to the manager.
    const leaveReview = onLeaveMode && !leaveFlagged;
    if (leaveReview) leaveFlagged = true;
    if (s.location_policy === "none") status = "not_requested";
    else if (r.kind !== "ok") status = "unavailable";
    else if (pos === "far-accuracy" || r.accuracy_m > s.max_accuracy_m) status = "inaccurate";
    else if (s.location_policy === "record") status = "recorded";
    else status = pos === "outside" ? "outside" : "inside";

    if (s.location_policy === "geofence" && status !== "inside") {
      if (s.outside_action === "reject") {
        if (status === "outside") throw new AppError("outside_geofence");
        if (status === "inaccurate") throw new AppError("location_inaccurate");
        throw new AppError("location_required");
      }
      review = true;
    }

    const result: PunchResult = {
      event_id: newRequestId(),
      action: orphan ? "check_out" : s.next_action,
      server_time: new Date(timeMs).toISOString(),
      location_status: status,
      needs_review: review || orphan || leaveReview,
      missing_checkin: orphan,
      on_approved_leave: onLeaveMode || undefined,
      recorded_offline: offline,
      duplicate: false,
      time_token: tokenAt(serverNow()),
    };
    byRequest.set(input.request_id, result);
    events.unshift({
      id: result.event_id, action: result.action, server_time: result.server_time,
      location_status: status, needs_review: review || orphan || leaveReview, recorded_offline: offline,
    });
    return result;
  }

  const req = createMockRequests();
  const ot = createMockOvertime();
  // notifications: settings in memory; the "server" test shows a local notification
  let notif = { remind_check_in: false, check_in_before: 10, remind_check_out: false, check_out_before: 0 };
  const devices = new Set<string>();

  return {
    ...req,
    ...ot,
    async savePushSubscription(k) { await wait(200); requireNetwork(); devices.add(k.endpoint); },
    async deletePushSubscription(endpoint) { await wait(200); requireNetwork(); devices.delete(endpoint); },
    async getNotificationSettings() { await wait(200); requireNetwork(); return { ...notif, devices: devices.size }; },
    async setNotificationSettings(s) {
      await wait(250); requireNetwork();
      if (s.check_in_before < 0 || s.check_in_before > 120 || s.check_out_before < 0 || s.check_out_before > 120) throw new AppError("invalid_input");
      notif = { ...s };
      return { ...notif, devices: devices.size };
    },
    async testNotification() {
      await wait(300); requireNetwork();
      if (devices.size === 0) throw new AppError("no_device");
      const reg = await navigator.serviceWorker?.ready;
      await reg?.showNotification("وقتي", { body: "الإشعارات تعمل على هذا الجهاز.", dir: "rtl", lang: "ar", tag: "test" });
    },
    async getSessionUser() {
      return user;
    },
    onAuthChange(cb) {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    async signIn(email, password) {
      await wait(500);
      if (password.length < 4) throw new AppError("invalid_credentials");
      user = { id: "mock-user", email, mustChangePassword: q.get("must_change") === "1" };
      save();
      notify();
    },
    async signInWithToken() {
      throw new AppError("forbidden"); // fingerprint sign-in needs the real server
    },
    async signOut() {
      user = null;
      save();
      notify();
    },
    async changeTemporaryPassword(p) {
      await wait(500);
      if ([...p].length < 8) throw new AppError("password_too_short");
      if (!/\p{L}/u.test(p) || !/\p{N}/u.test(p)) throw new AppError("password_too_weak");
      if (user) user = { ...user, mustChangePassword: false };
      if (q.get("statefail") === "1") stateFailUntil = Date.now() + 1500;
      save();
      notify();
    },
    async getProfileSummary() {
      await wait(300);
      requireNetwork();
      if (!user) throw new AppError("not_authenticated");
      if (q.get("summaryfail") === "1") throw new AppError("unknown");
      return mockSummary();
    },
    async getAttendanceState() {
      await wait(400);
      requireNetwork();
      if (!user) throw new AppError("not_authenticated");
      if (Date.now() < stateFailUntil || q.get("statefail") === "always") throw new AppError("network"); // always = server unreachable
      return state();
    },
    async punch(input: PunchInput) {
      await wait(700);
      requireNetwork();
      const result = record(input, serverNow(), false);
      // Flaky network: the server SAVED the punch, but the reply is lost.
      punchCount += 1;
      if (flaky && punchCount % 2 === 1) throw new AppError("network");
      return result;
    },
    async webauthn(action, body) {
      if (!bio) throw new AppError("forbidden"); // fingerprint needs the real server
      await wait(250);
      requireNetwork();
      if (action === "punch-options") {
        return { challenge: "bW9jay1jaGFsbGVuZ2U", rpId: "localhost", timeout: 60000, userVerification: "required",
                 allowCredentials: [{ id: "bW9jay1jcmVk", type: "public-key", transports: ["internal"] }] };
      }
      if (action === "punch-verify") return { ok: true };
      if (action === "register-options") {
        return { challenge: "bW9jay1yZWctY2hhbGxlbmdl", rp: { name: "Waqti", id: "localhost" },
                 user: { id: "bW9jay11c2Vy", name: "ahmed@example.com", displayName: "أحمد سالم" },
                 pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }], timeout: 60000,
                 authenticatorSelection: { authenticatorAttachment: "platform", userVerification: "required", residentKey: "preferred" },
                 attestation: "none" };
      }
      // ?regfail=1: the server answers "ok" but the device is not saved (the gate must not let the employee through)
      if (action === "register-verify") { if (q.get("regfail") !== "1") hasDevice = true; return { ok: true }; }
      if (action === "set-login") {
        loginEnabled = (body as { enabled: boolean }).enabled;
        return { login_enabled: loginEnabled };
      }
      throw new AppError("forbidden");
    },
    async punchOffline(input: OfflinePunchInput) {
      await wait(500);
      requireNetwork();
      const known = byRequest.get(input.request_id);
      if (known) return { ...known, duplicate: true, time_token: tokenAt(serverNow()) };
      const t0 = tokenTime(input.time_token);
      if (t0 === null) throw new AppError("time_unverified");
      const offsetThen = t0 - Date.parse(input.token_device_time);
      const offsetNow = serverNow() - Date.parse(input.device_now);
      if (Math.abs(offsetNow - offsetThen) > TOLERANCE_MS) throw new AppError("clock_changed");
      let claimed = Date.parse(input.device_time) + offsetThen;
      if (input.monotonic_ms !== null && claimed < t0 + input.monotonic_ms - TOLERANCE_MS) throw new AppError("clock_changed");
      if (claimed < t0 - 5000 || claimed > serverNow() + 5000) throw new AppError("clock_changed");
      if (claimed < serverNow() - MAX_OFFLINE_MS) throw new AppError("offline_too_old");
      claimed = Math.min(claimed, serverNow());
      return record(input, claimed, true);
    },
  };
}

// ---------------------------------------------------------------- requests (same rules as the server)

const TZ = "Africa/Tripoli";
const LEAVE_TYPES: LeaveType[] = ["annual", "sick", "emergency", "marriage", "unpaid"];
/** The 4 default permission types of a company (same as the server's defaults). Shift: 08:00-16:00, Friday off. */
const PERMISSION_TYPES = [
  { id: "pt-exit", name: "خروج أثناء الدوام", mode: "range" as const, max_per_month: 3, max_minutes: 120, days_back: 7, days_ahead: 30 },
  { id: "pt-final", name: "خروج نهائي من الدوام", mode: "early_leave" as const, max_per_month: 1, max_minutes: null, days_back: 7, days_ahead: 30 },
  { id: "pt-late", name: "تبرير تأخير", mode: "late_arrival" as const, max_per_month: 3, max_minutes: 60, days_back: 0, days_ahead: 0 },
  { id: "pt-mission", name: "مهمة عمل", mode: "range" as const, max_per_month: null, max_minutes: null, days_back: 7, days_ahead: 30 },
];
const SHIFT_START_H = 8;
const SHIFT_END_H = 16;
const ME = { full_name: "أحمد سالم", employee_number: "1024", department: "المبيعات", job_title: "مندوب" };

function createMockRequests() {
  const today = () => localDate(new Date(serverNow()).toISOString(), TZ);
  const startOfDay = (d: string) => new Date(Date.parse(`${d}T00:00:00Z`) - 2 * 3_600_000).toISOString(); // Tripoli = UTC+2
  const plusDays = (d: string, n: number) => new Date(Date.parse(`${d}T12:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
  /** Working days (Friday off), like the employee's weekly schedule on the server. */
  const workDays = (a: string, b: string) => {
    let n = 0;
    for (let d = a; d <= b; d = plusDays(d, 1)) if (new Date(`${d}T12:00:00Z`).getUTCDay() !== 5) n += 1;
    return n;
  };

  const mine: RequestItem[] = [];
  const byKey = new Map<string, string>();
  const steps = (manager: string, managerStatus: RequestItem["steps"][number]["status"], hrStatus: RequestItem["steps"][number]["status"]) => [
    { step_order: 1, kind: "direct_manager" as const, status: managerStatus, approver_name: manager, decided_at: null, note: null },
    { step_order: 2, kind: "hr" as const, status: hrStatus, approver_name: null, decided_at: null, note: null },
  ];
  const make = (over: Partial<RequestItem> & Pick<RequestItem, "type" | "start_at" | "end_at">): RequestItem => ({
    id: newRequestId(), leave_type: null, status: "pending", days: null, minutes: null, reason: null,
    decision_note: null, decided_at: null, created_at: new Date(serverNow()).toISOString(), current_step: 1,
    employee: ME, steps: steps("خالد المبروك", "pending", "waiting"), ...over,
  });

  if (onLeaveMode) {
    const t = today();
    mine.push(make({ type: "leave", leave_type: "annual", status: "cancelled", start_at: startOfDay(plusDays(t, -1)), end_at: startOfDay(plusDays(t, 2)), days: 3,
                     current_step: null, steps: steps("خالد المبروك", "approved", "approved"), created_at: startOfDay(plusDays(t, -10)),
                     decision_note: "أُلغيت إجازتك بسبب تسجيل حضورك يوم " + t }));
    // a leave the administration cut in the middle: the later part is its own approved request carrying the note
    mine.push(make({ type: "leave", leave_type: "annual", status: "approved", start_at: startOfDay(plusDays(t, 3)), end_at: startOfDay(plusDays(t, 6)), days: 3,
                     current_step: null, steps: steps("خالد المبروك", "approved", "approved"), created_at: startOfDay(plusDays(t, -12)),
                     decision_note: "أُلغيت أيام من إجازتك (" + plusDays(t, 2) + ") بسبب تسجيل حضورك يوم " + t }));
  }
  if (q.get("requests") === "1") {
    const t = today();
    mine.push(
      make({ type: "leave", leave_type: "annual", status: "approved", start_at: startOfDay(plusDays(t, -20)), end_at: startOfDay(plusDays(t, -17)),
             days: 3, current_step: null, steps: steps("خالد المبروك", "approved", "approved"), created_at: startOfDay(plusDays(t, -25)) }),
      make({ type: "permission", permission_type_id: "pt-exit", permission_type: "خروج أثناء الدوام", status: "rejected", start_at: new Date(Date.parse(startOfDay(plusDays(t, -3))) + 10 * 3_600_000).toISOString(),
             end_at: new Date(Date.parse(startOfDay(plusDays(t, -3))) + 12 * 3_600_000).toISOString(), minutes: 120, current_step: null,
             decision_note: "ضغط عمل في هذا اليوم", steps: steps("خالد المبروك", "rejected", "cancelled"), created_at: startOfDay(plusDays(t, -4)) }),
      make({ type: "leave", leave_type: "annual", start_at: startOfDay(plusDays(t, 12)), end_at: startOfDay(plusDays(t, 15)), days: 3,
             reason: "سفر عائلي", created_at: startOfDay(plusDays(t, -1)) }),
    );
  }

  const inbox: InboxItem[] = [];
  if (q.get("inbox") !== "0") {
    const t = today();
    const other = (name: string, number: string) => ({ full_name: name, employee_number: number, department: "المبيعات", job_title: "مندوب" });
    inbox.push(
      { ...make({ type: "leave", leave_type: "annual", start_at: startOfDay(plusDays(t, 5)), end_at: startOfDay(plusDays(t, 8)), days: 3,
                  reason: "زواج أخي", employee: other("سالم الورفلي", "1031"), steps: steps("أحمد سالم", "pending", "waiting") }),
        approval_id: newRequestId(), my_step: 1, step_count: 2,
        balance: { leave_type: "annual", entitled: 30, used: 9, pending: 0, remaining: 21 }, permission: null },
      { ...make({ type: "permission", permission_type_id: "pt-exit", permission_type: "خروج أثناء الدوام", start_at: new Date(Date.parse(startOfDay(plusDays(t, 1))) + 9 * 3_600_000).toISOString(),
                  end_at: new Date(Date.parse(startOfDay(plusDays(t, 1))) + 11 * 3_600_000).toISOString(), minutes: 120,
                  reason: "مراجعة طبية", employee: other("مريم التاجوري", "1040"), steps: steps("أحمد سالم", "pending", "waiting") }),
        approval_id: newRequestId(), my_step: 1, step_count: 2, balance: null,
        permission: { ...PERMISSION_TYPES[0], month: t.slice(0, 7), used: 1, pending: 0 } },
    );
  }

  function balance(type: LeaveType, year: string, exclude?: string): LeaveBalance {
    const entitled = type === "annual" ? 30 : null;
    const rows = mine.filter((r) => r.type === "leave" && r.leave_type === type && r.id !== exclude && localDate(r.start_at, TZ).startsWith(year));
    const used = rows.filter((r) => r.status === "approved").reduce((a, r) => a + (r.days ?? 0), 0);
    const pending = rows.filter((r) => r.status === "pending").reduce((a, r) => a + (r.days ?? 0), 0);
    return { leave_type: type, entitled, used, pending, remaining: entitled === null ? null : entitled - used - pending };
  }
  function permission(typeId: string, month: string): PermissionUsage {
    const pt = PERMISSION_TYPES.find((x) => x.id === typeId)!;
    const rows = mine.filter((r) => r.permission_type_id === typeId && localDate(r.start_at, TZ).startsWith(month));
    const count = (st: string) => rows.filter((r) => r.status === st).length;
    return { ...pt, month, used: count("approved"), pending: count("pending") };
  }
  const atHour = (day: string, h: number) => new Date(Date.parse(startOfDay(day)) + h * 3_600_000).toISOString();

  function check(r: NewRequest): RequestPreview {
    const t = today();
    let start: string, end: string, days: number | null = null, minutes: number | null = null;
    let bal: LeaveBalance | null = null, perm: PermissionUsage | null = null;
    if (r.type === "permission") {
      const pt = PERMISSION_TYPES.find((x) => x.id === r.permission_type_id);
      if (!pt) throw new AppError("permission_type_not_found");
      const day = localDate((r.start_at ?? r.end_at)!, TZ);
      const workday = new Date(`${day}T12:00:00Z`).getUTCDay() !== 5;
      if (pt.mode === "range") {
        if (!r.start_at || !r.end_at || Date.parse(r.end_at) <= Date.parse(r.start_at)
            || localDate(new Date(Date.parse(r.end_at) - 1000).toISOString(), TZ) !== day) throw new AppError("invalid_dates");
        start = r.start_at; end = r.end_at;
      } else if (pt.mode === "late_arrival") {
        if (!r.end_at) throw new AppError("invalid_dates");
        if (!workday) throw new AppError("no_working_days");
        start = atHour(day, SHIFT_START_H); end = r.end_at;
        if (Date.parse(end) <= Date.parse(start)) throw new AppError("not_late");
        if (Date.parse(end) > Date.parse(atHour(day, SHIFT_END_H))) throw new AppError("invalid_dates");
      } else {
        if (!r.start_at) throw new AppError("invalid_dates");
        if (!workday) throw new AppError("no_working_days");
        start = r.start_at; end = atHour(day, SHIFT_END_H);
        if (Date.parse(start) >= Date.parse(end) || Date.parse(start) < Date.parse(atHour(day, SHIFT_START_H))) throw new AppError("invalid_dates");
      }
      minutes = Math.ceil((Date.parse(end) - Date.parse(start)) / 60_000);
      if (pt.max_minutes !== null && minutes > pt.max_minutes) throw new AppError("permission_too_long");
      if (day < plusDays(t, -pt.days_back) || day > plusDays(t, pt.days_ahead)) throw new AppError("outside_window");
      perm = permission(pt.id, day.slice(0, 7));
      if (pt.max_per_month !== null && perm.used + perm.pending >= pt.max_per_month) throw new AppError("permission_limit");
    } else {
      if (r.end_date < r.start_date || r.start_date < plusDays(t, -30) || r.start_date > plusDays(t, 365)) throw new AppError("invalid_dates");
      if (r.type === "other" && !r.reason) throw new AppError("reason_required");
      if (r.type === "leave") {
        if (r.start_date.slice(0, 4) !== r.end_date.slice(0, 4)) throw new AppError("crosses_year");
        days = workDays(r.start_date, r.end_date);
        if (days === 0) throw new AppError("no_working_days");
        bal = balance(r.leave_type, r.start_date.slice(0, 4));
        if (bal.remaining !== null && bal.remaining < days) throw new AppError("insufficient_balance");
      }
      start = startOfDay(r.start_date); end = startOfDay(plusDays(r.end_date, 1));
    }
    if (r.type !== "other") {
      const overlap = mine.some((x) => x.type !== "other" && (x.status === "pending" || x.status === "approved")
        && Date.parse(x.start_at) < Date.parse(end) && Date.parse(start) < Date.parse(x.end_at));
      if (overlap) throw new AppError("overlapping_request");
    }
    return { start_at: start, end_at: end, days, minutes, balance: bal, permission: perm };
  }

  const online = async (ms: number) => {
    await wait(ms);
    requireNetwork();
  };

  return {
    async getRequestsOverview() {
      await online(350);
      const t = today();
      return {
        balances: LEAVE_TYPES.map((x) => balance(x, t.slice(0, 4))),
        permission_types: PERMISSION_TYPES.map((pt) => permission(pt.id, t.slice(0, 7))),
        requests: [...mine].sort((a, b) => b.created_at.localeCompare(a.created_at)),
        inbox_count: inbox.length,
        timezone: TZ,
        today: t,
        leave_earliest: addDays(t, leaveNotice - leaveBack),
      };
    },
    async previewRequest(r: NewRequest) {
      await online(250);
      return check(r);
    },
    async submitRequest(key: string, r: NewRequest) {
      await online(600);
      const known = byKey.get(key);
      if (known) return mine.find((x) => x.id === known)!;
      if (r.type === "leave" && r.start_date < addDays(today(), leaveNotice - leaveBack)) throw new AppError("leave_date_not_allowed");
      const p = check(r);
      const pt = r.type === "permission" ? PERMISSION_TYPES.find((x) => x.id === r.permission_type_id) : undefined;
      const item = make({ type: r.type, leave_type: r.type === "leave" ? r.leave_type : null, start_at: p.start_at, end_at: p.end_at,
                          permission_type_id: pt?.id ?? null, permission_type: pt?.name ?? null,
                          days: p.days, minutes: p.minutes, reason: r.reason });
      mine.push(item);
      byKey.set(key, item.id);
      return item;
    },
    async cancelRequest(id: string) {
      await online(400);
      const r = mine.find((x) => x.id === id);
      if (!r) throw new AppError("request_not_found");
      if (r.status === "cancelled") return r;
      if (r.status !== "pending") throw new AppError("already_decided");
      r.status = "cancelled";
      r.current_step = null;
      r.steps = r.steps.map((s) => (s.status === "pending" || s.status === "waiting" ? { ...s, status: "cancelled" } : s));
      return r;
    },
    async getInbox() {
      await online(350);
      return [...inbox];
    },
    async decide(approvalId: string, decision: "approve" | "reject", note: string | null) {
      await online(500);
      const i = inbox.findIndex((x) => x.approval_id === approvalId);
      if (i < 0) throw new AppError("request_not_found");
      const [item] = inbox.splice(i, 1);
      const now = new Date(serverNow()).toISOString();
      const stepsAfter = item.steps.map((s) =>
        s.step_order === item.my_step ? { ...s, status: decision === "approve" ? ("approved" as const) : ("rejected" as const), decided_at: now, note }
          : s.status === "waiting" ? { ...s, status: decision === "approve" ? ("pending" as const) : ("cancelled" as const) } : s);
      return { ...item, steps: stepsAfter, status: decision === "reject" ? "rejected" : "pending",
               current_step: decision === "reject" ? null : item.my_step + 1, decision_note: decision === "reject" ? note : null } as RequestItem;
    },
  };
}

// ---------------------------------------------------------------- overtime (same rules as the server)

function createMockOvertime() {
  const TZ_ = "Africa/Tripoli";
  const iso = (ms: number) => new Date(ms).toISOString();
  const today = () => localDate(iso(serverNow()), TZ_);
  const at = (day: string, h: number, m = 0) => iso(Date.parse(`${day}T00:00:00Z`) - 2 * 3_600_000 + (h * 60 + m) * 60_000);
  const plusDays = (d: string, n: number) => new Date(Date.parse(`${d}T12:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
  const SHIFT = [8, 16]; // every day except Friday
  const isWorkday = (day: string) => new Date(`${day}T12:00:00Z`).getUTCDay() !== 5;
  const limits = { day_minutes: 180 as number | null, month_minutes: 1200 as number | null };
  const ME = { id: "me", full_name: "أحمد سالم" };
  const team: TeamMember[] = q.get("overtime") === "1" ? [
    { id: "t1", full_name: "سالم الورفلي", employee_number: "1031", department: "المبيعات", direct: true },
    { id: "t2", full_name: "مريم التاجوري", employee_number: "1040", department: "المبيعات", direct: true },
    { id: "t3", full_name: "علي الزوي", employee_number: "1052", department: "المخازن", direct: false },
  ] : [];
  const items: OvertimeItem[] = [];
  const byKey = new Map<string, string>();
  const phaseOf = (o: OvertimeItem): OvertimeItem["phase"] =>
    o.status === "cancelled" ? "cancelled" : serverNow() < Date.parse(o.start_at) ? "upcoming" : serverNow() < Date.parse(o.end_at) ? "now" : "done";
  const make = (emp: { id: string; full_name: string }, by: { id: string; full_name: string }, s: string, e: string, task: string | null): OvertimeItem => ({
    id: newRequestId(), status: "assigned", phase: "upcoming", start_at: s, end_at: e, minutes: Math.ceil((Date.parse(e) - Date.parse(s)) / 60_000), task,
    employee: { id: emp.id, full_name: emp.full_name, employee_number: null, department: null }, assigned_by: by,
    employee_note: null, employee_noted_at: null, cancelled_at: null, cancelled_by_name: null, created_at: iso(serverNow()), actual_minutes: null,
  });
  if (q.get("overtime") === "1") {
    const d = plusDays(today(), 2);
    items.push(make(ME, { id: "boss", full_name: "خالد المبروك" }, at(d, 16, 30), at(d, 18, 30), "جرد المخزن الرئيسي"));
    const past = make({ id: "t1", full_name: "سالم الورفلي" }, ME, at(plusDays(today(), -3), 16), at(plusDays(today(), -3), 18), null);
    past.actual_minutes = 95;
    items.push(past);
  }
  const view = (o: OvertimeItem) => ({ ...o, phase: phaseOf(o) });

  function check(i: OvertimeInput): OvertimePreview {
    const member = team.find((t) => t.id === i.employee_id);
    if (!member) throw new AppError("not_your_team");
    const s = Date.parse(i.start_at), e = Date.parse(i.end_at);
    const day = localDate(i.start_at, TZ_);
    if (!(e > s) || localDate(iso(e - 1000), TZ_) !== day) throw new AppError("invalid_dates");
    if (s < serverNow() - 15 * 60_000 || day > plusDays(today(), 60)) throw new AppError("invalid_dates");
    const minutes = Math.ceil((e - s) / 60_000);
    if (minutes < 15) throw new AppError("invalid_duration");
    const shift = isWorkday(day) ? [Date.parse(at(day, SHIFT[0])), Date.parse(at(day, SHIFT[1]))] : null;
    if (shift && s < shift[1] && shift[0] < e) throw new AppError("overlaps_shift");
    const active = items.filter((o) => o.employee.id === i.employee_id && o.status === "assigned");
    if (active.some((o) => Date.parse(o.start_at) < e && s < Date.parse(o.end_at))) throw new AppError("overlapping_overtime");
    const usedDay = active.filter((o) => localDate(o.start_at, TZ_) === day).reduce((a, o) => a + o.minutes, 0);
    const usedMonth = active.filter((o) => localDate(o.start_at, TZ_).slice(0, 7) === day.slice(0, 7)).reduce((a, o) => a + o.minutes, 0);
    if (limits.day_minutes !== null && usedDay + minutes > limits.day_minutes) throw new AppError("overtime_day_limit");
    if (limits.month_minutes !== null && usedMonth + minutes > limits.month_minutes) throw new AppError("overtime_month_limit");
    return { minutes, used_day: usedDay, used_month: usedMonth, limit_day: limits.day_minutes, limit_month: limits.month_minutes,
             shift_start: shift ? iso(shift[0]) : null, shift_end: shift ? iso(shift[1]) : null };
  }
  const online = async (ms: number) => {
    await wait(ms);
    requireNetwork();
  };

  return {
    async getOvertimeOverview(): Promise<OvertimeOverview> {
      await online(300);
      return {
        mine: items.filter((o) => o.employee.id === ME.id).map(view),
        team,
        assigned_by_me: items.filter((o) => o.assigned_by.id === ME.id).map(view).sort((a, b) => b.start_at.localeCompare(a.start_at)),
        limits: { ...limits }, timezone: TZ_, today: today(),
      };
    },
    async previewOvertime(i: OvertimeInput) {
      await online(250);
      return check(i);
    },
    async assignOvertime(key: string, i: OvertimeInput) {
      await online(500);
      const known = byKey.get(key);
      if (known) return view(items.find((o) => o.id === known)!);
      check(i);
      const member = team.find((t) => t.id === i.employee_id)!;
      const o = make(member, ME, i.start_at, i.end_at, i.task);
      items.push(o);
      byKey.set(key, o.id);
      return view(o);
    },
    async cancelOvertime(id: string) {
      await online(350);
      const o = items.find((x) => x.id === id);
      if (!o) throw new AppError("overtime_not_found");
      if (serverNow() >= Date.parse(o.start_at)) throw new AppError("overtime_started");
      o.status = "cancelled"; o.cancelled_at = iso(serverNow()); o.cancelled_by_name = ME.full_name;
      return view(o);
    },
    async noteOvertime(id: string, note: string) {
      await online(350);
      const o = items.find((x) => x.id === id && x.employee.id === ME.id);
      if (!o) throw new AppError("overtime_not_found");
      if (o.status === "cancelled" || serverNow() >= Date.parse(o.end_at)) throw new AppError("overtime_closed");
      o.employee_note = note.trim(); o.employee_noted_at = iso(serverNow());
      return view(o);
    },
  };
}
