// Attendance screen state machine (pure: no network, no DOM, easy to test).
//
//   loading ──► ready ──tap──► locating ──► submitting ──ok──► ready (+ success notice) ──► refresh
//      │          ▲                              │
//      ▼          │                              ├─ clear server error ──► ready (+ error notice)
//   load_error    │                              └─ network error ─────► unconfirmed
//                 └──────── refresh ◄──────────────────────────────────────┘ │
//                                                    retry (SAME request_id) ◄┘
//
// Offline (company allows it): a tap with no connection, or a tap whose reply is lost, is saved on the
// phone (QUEUED) and sent later by the offline queue. See offlineQueue.ts.
//
// Rules:
// - Online, the button label comes from the SERVER (next_action). Offline, it is the last server
//   state plus the punches still waiting on the phone (withQueue).
// - Success is shown only after the server answers.
// - After a network error we do not know if the punch was saved, so we never say "failed" or
//   "saved". A retry reuses the same request_id, so the server can never record it twice.

import { clockParts, format12, zonedHMS } from "./time12";
import { AppError, ERROR_TEXT } from "./errors";
import type { AttendanceAction, AttendanceState, LocationReading, LocationStatus, PunchResult } from "./types";

export interface Pending {
  request_id: string;
  action: AttendanceAction;
  reading: LocationReading | null;
  /** Fingerprint result for this punch (phase 8b): "ticket" (done, or not required) or "unsupported". */
  biometric?: "ticket" | "unsupported";
}

export type NoticeKind = "success" | "warning" | "error";
export interface Notice {
  kind: NoticeKind;
  text: string;
}

export type ScreenState =
  | { phase: "loading" }
  | { phase: "load_error"; error: AppError }
  | { phase: "ready"; data: AttendanceState; notice: Notice | null; refreshing: boolean }
  | { phase: "locating"; data: AttendanceState; pending: Pending }
  | { phase: "submitting"; data: AttendanceState; pending: Pending }
  | { phase: "unconfirmed"; data: AttendanceState; pending: Pending };

export type ScreenEvent =
  | { type: "LOAD_START" }
  | { type: "LOAD_OK"; data: AttendanceState }
  | { type: "LOAD_FAIL"; error: AppError }
  | { type: "TAP"; request_id: string; action: AttendanceAction }
  | { type: "QUEUED"; at: string }
  | { type: "LOCATED"; reading: LocationReading }
  | { type: "PUNCH_OK"; result: PunchResult }
  | { type: "PUNCH_FAIL"; error: AppError }
  | { type: "RETRY" }
  | { type: "DISMISS_NOTICE" };

export const initialState: ScreenState = { phase: "loading" };

export function reduce(state: ScreenState, event: ScreenEvent): ScreenState {
  switch (event.type) {
    case "LOAD_START":
      if (state.phase === "ready") return { ...state, refreshing: true };
      if (state.phase === "loading" || state.phase === "load_error") return { phase: "loading" };
      return state; // never interrupt a punch in progress

    case "LOAD_OK":
      if (state.phase === "ready") return { ...state, data: event.data, refreshing: false };
      if (state.phase === "loading" || state.phase === "load_error" || state.phase === "unconfirmed")
        // After an unconfirmed punch, fresh server state is the truth: show it and drop the pending tap.
        return { phase: "ready", data: event.data, notice: null, refreshing: false };
      return state;

    case "LOAD_FAIL":
      if (state.phase === "ready") return { ...state, refreshing: false };
      if (state.phase === "loading") return { phase: "load_error", error: event.error };
      return state;

    case "TAP": {
      if (state.phase !== "ready") return state; // ignores double taps while busy
      const pending: Pending = { request_id: event.request_id, action: event.action, reading: null };
      return { phase: "locating", data: state.data, pending };
    }

    case "LOCATED":
      if (state.phase !== "locating") return state;
      return { phase: "submitting", data: state.data, pending: { ...state.pending, reading: event.reading } };

    case "PUNCH_OK":
      if (state.phase !== "submitting") return state;
      return {
        phase: "ready",
        data: applyResult(state.data, event.result),
        notice: successNotice(event.result, state.data.company.timezone),
        refreshing: false,
      };

    case "PUNCH_FAIL":
      if (state.phase !== "submitting") return state;
      if (event.error.code === "network") return { phase: "unconfirmed", data: state.data, pending: state.pending };
      return {
        phase: "ready",
        data: state.data,
        notice: { kind: "error", text: ERROR_TEXT[event.error.code] },
        refreshing: false,
      };

    case "QUEUED":
      if (state.phase !== "locating" && state.phase !== "submitting" && state.phase !== "unconfirmed") return state;
      return {
        phase: "ready",
        data: state.data,
        notice: queuedNotice(state.pending.action, event.at, state.data.company.timezone),
        refreshing: false,
      };

    case "RETRY":
      if (state.phase !== "unconfirmed") return state;
      return { phase: "submitting", data: state.data, pending: state.pending };

    case "DISMISS_NOTICE":
      return state.phase === "ready" ? { ...state, notice: null } : state;
  }
}

/** Shows the server's answer right away; a full refresh from the server follows. */
function applyResult(data: AttendanceState, r: PunchResult): AttendanceState {
  const event = {
    id: r.event_id,
    action: r.action,
    server_time: r.server_time,
    location_status: r.location_status,
    needs_review: r.needs_review,
    recorded_offline: r.recorded_offline ?? false,
  };
  return {
    ...data,
    next_action: r.action === "check_in" ? "check_out" : "check_in",
    can_check_out_without_in: false,
    forgot_check_in: false,
    open_session: r.action === "check_in" ? { started_at: r.server_time } : null,
    recent_events: [event, ...data.recent_events.filter((e) => e.id !== r.event_id)].slice(0, 10),
    server_time: r.server_time,
  };
}

const REVIEW_REASON: Partial<Record<LocationStatus, string>> = {
  outside: "خارج نطاق مكان العمل",
  unavailable: "الموقع غير متاح",
  inaccurate: "دقة الموقع ضعيفة",
};

export function successNotice(r: PunchResult, timeZone: string): Notice {
  const what = r.action === "check_in" ? "الحضور" : "الانصراف";
  const at = formatTime(r.server_time, timeZone);
  if (r.missing_checkin) {
    return { kind: "warning", text: `تم تسجيل الانصراف الساعة ${at} بدون حضور مسجّل، وسيُراجع من الإدارة.` };
  }
  if (r.needs_review) {
    const why = REVIEW_REASON[r.location_status] ?? "يحتاج مراجعة";
    return { kind: "warning", text: `تم تسجيل ${what} الساعة ${at}، مع ملاحظة للمراجعة: ${why}.` };
  }
  return { kind: "success", text: `تم تسجيل ${what} الساعة ${at}.` };
}

export function queuedNotice(action: AttendanceAction, at: string, timeZone: string): Notice {
  const what = action === "check_in" ? "الحضور" : "الانصراف";
  return {
    kind: "warning",
    text: `حُفظ ${what} على هذا الجهاز الساعة ${formatTime(at, timeZone)}، ولم يُعتمد بعد. يُرسل تلقائيًا عند عودة الإنترنت.`,
  };
}

export function actionLabel(a: AttendanceAction): string {
  return a === "check_in" ? "تسجيل الحضور" : "تسجيل الانصراف";
}

export function formatTime(iso: string, timeZone: string): string {
  const { h, m } = zonedHMS(iso, timeZone);
  return format12(h, m);
}

/** Live clock with seconds ("8:05:09 م"). Stamps and history use formatTime. */
export function formatClock(iso: string, timeZone: string): string {
  const c = clockParts(iso, timeZone);
  return `${c.hm}:${c.ss} ${c.period}`;
}

export function formatDate(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("ar-LY", {
    timeZone,
    weekday: "long",
    day: "numeric",
    month: "long",
    numberingSystem: "latn",
  }).format(new Date(iso));
}

/** Server clock minus device clock, so the shown time follows the server, not the phone. */
export function clockOffsetMs(serverIso: string, deviceNow: number = Date.now()): number {
  return new Date(serverIso).getTime() - deviceNow;
}

/** UUID v4 for the idempotency key. Falls back to getRandomValues on browsers without randomUUID. */
export function newRequestId(c: Pick<Crypto, "getRandomValues"> & Partial<Pick<Crypto, "randomUUID">> = crypto): string {
  if (typeof c.randomUUID === "function") return c.randomUUID();
  const b = c.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
