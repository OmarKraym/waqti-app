// Fake server for UI work and demos (VITE_MOCK=1). Not used in production builds with VITE_MOCK=0.
// Behaves like the real contract, including idempotency and the location policies.
// Change the scenario from the URL, e.g. ?policy=geofence&outside=reject&pos=outside&net=flaky
//   policy = geofence | record | none        outside = flag | reject
//   pos    = inside | outside | far-accuracy  net     = ok | flaky (every 2nd punch loses its reply)
//   must_change = 1  (first login: forced password change)
// With no connection (navigator.onLine === false) every call fails like a real network error.
// Offline punches are checked like the real server: signed-time token, clock consistency (+-120 s),
// one-sided monotonic check, 72 h limit, time order.

import type { SessionUser, WaqtiApi } from "./api";
import { newRequestId } from "./attendance";
import { AppError } from "./errors";
import type { AttendanceEvent, AttendanceState, LocationStatus, OfflinePunchInput, PunchInput, PunchResult } from "./types";

const q = new URLSearchParams(globalThis.location?.search ?? "");
const policy = (q.get("policy") ?? "geofence") as AttendanceState["location_policy"];
const outside = (q.get("outside") ?? "flag") as AttendanceState["outside_action"];
const pos = q.get("pos") ?? "inside";
const flaky = q.get("net") === "flaky";
const MAX_OFFLINE_MS = 72 * 3_600_000;
const TOLERANCE_MS = 120_000;

/** Stand-in for the server's signed token (the mock has nothing to protect). */
const tokenAt = (ms: number) => `mock.${ms}`;
const tokenTime = (t: string) => (/^mock\.\d+$/.test(t) ? Number(t.slice(5)) : null);

function requireNetwork(): void {
  if (globalThis.navigator && navigator.onLine === false) throw new AppError("network", "offline");
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The fake SERVER clock: real time, not affected when a test moves the phone clock (Date.now). */
const serverNow = (): number =>
  globalThis.performance ? Math.round(performance.timeOrigin + performance.now()) : Date.now();

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

  const events: AttendanceEvent[] = [];
  const byRequest = new Map<string, PunchResult>();
  let punchCount = 0;

  const state = (): AttendanceState => {
    const last = events[0];
    const open = last?.action === "check_in";
    return {
      employee: { full_name: "أحمد سالم", employee_number: "1024" },
      company: { name: "شركة تجريبية", timezone: "Africa/Tripoli" },
      next_action: open ? "check_out" : "check_in",
      open_session: open ? { started_at: last.server_time } : null,
      location_policy: policy,
      outside_action: outside,
      max_accuracy_m: 100,
      recent_events: events.slice(0, 10),
      server_time: new Date(serverNow()).toISOString(),
      time_token: tokenAt(serverNow()),
    };
  };

  /** Same decision logic for online (time = now) and offline (time = verified claimed time). */
  function record(input: PunchInput, timeMs: number, offline: boolean): PunchResult {
    const known = byRequest.get(input.request_id);
    if (known) return { ...known, duplicate: true, time_token: tokenAt(serverNow()) };
    if (events[0] && timeMs <= Date.parse(events[0].server_time)) throw new AppError("time_order");

    const s = state();
    if (input.expected_action !== s.next_action) throw new AppError("state_changed");

    const r = input.reading;
    let status: LocationStatus;
    let review = false;
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
      action: s.next_action,
      server_time: new Date(timeMs).toISOString(),
      location_status: status,
      needs_review: review,
      recorded_offline: offline,
      duplicate: false,
      time_token: tokenAt(serverNow()),
    };
    byRequest.set(input.request_id, result);
    events.unshift({
      id: result.event_id, action: result.action, server_time: result.server_time,
      location_status: status, needs_review: review, recorded_offline: offline,
    });
    return result;
  }

  return {
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
      save();
      notify();
    },
    async getAttendanceState() {
      await wait(400);
      requireNetwork();
      if (!user) throw new AppError("not_authenticated");
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
