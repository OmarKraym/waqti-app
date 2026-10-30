// Offline punches: kept on the phone, sent in order when the internet is back.
//
// Rules (decided by Omar, 2026-10-30)
// - Accepted ONLY if the phone clock is consistent (checked by the server, no admin review).
// - Refused if it reaches the server more than 72 hours after the punch (covers the weekend).
// - Location rules are the same as online (geofence + reject = refused, and the employee sees why).
//
// How the time is proven
// - Every server answer carries a signed "time token" (server time). The phone keeps the latest one
//   as its ANCHOR, with the phone clock (and the monotonic clock) at the moment it arrived.
// - A punch records the phone clock at the tap and, if the app stayed open since the anchor, the
//   monotonic time elapsed. The server compares both with the phone clock at sending.
//
// Other rules
// - One queue per user (a shared phone never mixes employees). It survives logout.
// - Each punch keeps its request_id forever: sending it twice can never record it twice.
// - A refused punch is kept as "failed" with the reason until the employee dismisses it.
// - Pure functions + a tiny storage adapter, so everything here is unit-tested without a browser.

import { AppError, toKnownCode, type AppErrorCode } from "./errors";
import type {
  AttendanceAction,
  AttendanceEvent,
  AttendanceState,
  LocationReading,
  OfflinePunchInput,
  PunchResult,
} from "./types";

/** The latest signed server time this phone has, and the phone clocks when it arrived. */
export interface TimeAnchor {
  token: string;
  server_time_ms: number;
  device_time_ms: number;
  /** performance.now() when it arrived; null if it came from storage (app restarted since). */
  perf_ms: number | null;
}

export interface QueuedPunch {
  request_id: string;
  action: AttendanceAction;
  reading: LocationReading;
  /** Corrected time of the tap (ISO) — what the employee sees. */
  offline_at: string;
  /** Raw phone time of the tap (ms since epoch). */
  device_time_ms: number;
  time_token: string;
  token_device_time_ms: number;
  monotonic_ms: number | null;
  status: "pending" | "failed";
  error_code?: AppErrorCode;
}

export interface Storage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const QUEUE_KEY = (userId: string) => `waqti-queue:${userId}`;
const STATE_KEY = (userId: string) => `waqti-state:${userId}`;

/** localStorage when it works; null when blocked (private mode, disabled storage). */
export function browserStorage(): Storage | null {
  try {
    const s = globalThis.localStorage;
    const probe = "waqti-probe";
    s.setItem(probe, "1");
    s.removeItem(probe);
    return s;
  } catch {
    return null;
  }
}

// ------------------------------------------------------------------ anchor

export function anchorFromServer(
  token: string,
  serverIso: string,
  deviceNowMs: number = Date.now(),
  perfNowMs: number | null = globalThis.performance?.now() ?? null,
): TimeAnchor {
  return { token, server_time_ms: Date.parse(serverIso), device_time_ms: deviceNowMs, perf_ms: perfNowMs };
}

/** Server clock minus phone clock, as measured by this anchor. */
export function anchorOffsetMs(a: TimeAnchor): number {
  return a.server_time_ms - a.device_time_ms;
}

// ------------------------------------------------------------------ queue storage

function isQueuedPunch(x: unknown): x is QueuedPunch {
  const q = x as QueuedPunch;
  return !!q && typeof q.request_id === "string" && typeof q.time_token === "string" && typeof q.device_time_ms === "number";
}

export function loadQueue(storage: Storage | null, userId: string): QueuedPunch[] {
  if (!storage) return [];
  try {
    const raw = storage.getItem(QUEUE_KEY(userId));
    const parsed: unknown = raw ? JSON.parse(raw) : [];
    // Items in an unknown format (e.g. an old build) cannot be proven: they are dropped, not sent.
    return Array.isArray(parsed) ? parsed.filter(isQueuedPunch) : [];
  } catch {
    return [];
  }
}

/** Returns false when the phone refused to save (then the punch must NOT be treated as recorded). */
export function saveQueue(storage: Storage | null, userId: string, queue: QueuedPunch[]): boolean {
  if (!storage) return false;
  try {
    if (queue.length === 0) storage.removeItem(QUEUE_KEY(userId));
    else storage.setItem(QUEUE_KEY(userId), JSON.stringify(queue));
    return true;
  } catch {
    return false;
  }
}

// ------------------------------------------------------------------ last known server state (to open the app offline)

export interface CachedState {
  data: AttendanceState;
  /** Phone time when data arrived. */
  saved_at_ms: number;
}

export function saveCachedState(storage: Storage | null, userId: string, cached: CachedState): void {
  if (!storage) return;
  try {
    storage.setItem(STATE_KEY(userId), JSON.stringify(cached));
  } catch {
    /* not critical */
  }
}

export function loadCachedState(storage: Storage | null, userId: string): CachedState | null {
  if (!storage) return null;
  try {
    const raw = storage.getItem(STATE_KEY(userId));
    const parsed = raw ? (JSON.parse(raw) as CachedState) : null;
    return parsed && typeof parsed.data?.time_token === "string" && typeof parsed.saved_at_ms === "number" ? parsed : null;
  } catch {
    return null;
  }
}

export function anchorFromCache(c: CachedState): TimeAnchor {
  return { token: c.data.time_token, server_time_ms: Date.parse(c.data.server_time), device_time_ms: c.saved_at_ms, perf_ms: null };
}

// ------------------------------------------------------------------ building and showing

export function makeQueuedPunch(
  request_id: string,
  action: AttendanceAction,
  reading: LocationReading,
  anchor: TimeAnchor,
  device_time_ms: number = Date.now(),
  perf_now_ms: number | null = globalThis.performance?.now() ?? null,
): QueuedPunch {
  return {
    request_id,
    action,
    reading,
    offline_at: new Date(device_time_ms + anchorOffsetMs(anchor)).toISOString(),
    device_time_ms,
    time_token: anchor.token,
    token_device_time_ms: anchor.device_time_ms,
    monotonic_ms: anchor.perf_ms !== null && perf_now_ms !== null ? Math.max(0, Math.round(perf_now_ms - anchor.perf_ms)) : null,
    status: "pending",
  };
}

export function pendingOf(queue: QueuedPunch[]): QueuedPunch[] {
  return queue.filter((q) => q.status === "pending");
}

export function failedOf(queue: QueuedPunch[]): QueuedPunch[] {
  return queue.filter((q) => q.status === "failed");
}

/**
 * The screen = last server state + punches still waiting on the phone.
 * The next action flips once per waiting punch, so a check-in made offline is followed by check-out.
 */
export function withQueue(data: AttendanceState, queue: QueuedPunch[]): AttendanceState {
  const pending = pendingOf(queue);
  if (pending.length === 0) return data;
  const last = pending[pending.length - 1];
  const events: AttendanceEvent[] = pending
    .slice()
    .reverse()
    .map((q) => ({
      id: `queued:${q.request_id}`,
      action: q.action,
      server_time: q.offline_at,
      location_status: "not_requested",
      needs_review: false,
      recorded_offline: true,
    }));
  return {
    ...data,
    next_action: last.action === "check_in" ? "check_out" : "check_in",
    open_session: last.action === "check_in" ? { started_at: last.offline_at } : null,
    recent_events: [...events, ...data.recent_events].slice(0, 10),
  };
}

export function isQueuedEvent(e: AttendanceEvent): boolean {
  return e.id.startsWith("queued:");
}

export function toOfflineInput(q: QueuedPunch, deviceNowMs: number = Date.now()): OfflinePunchInput {
  return {
    request_id: q.request_id,
    expected_action: q.action,
    reading: q.reading,
    time_token: q.time_token,
    token_device_time: new Date(q.token_device_time_ms).toISOString(),
    device_time: new Date(q.device_time_ms).toISOString(),
    monotonic_ms: q.monotonic_ms,
    device_now: new Date(deviceNowMs).toISOString(),
  };
}

// ------------------------------------------------------------------ sending

export interface SyncResult {
  queue: QueuedPunch[];
  sent: PunchResult[];
  /** Newly refused punches in this run. */
  refused: QueuedPunch[];
  /** true = stopped because there is still no connection (the rest stays pending). */
  stoppedOffline: boolean;
}

/**
 * Sends waiting punches one by one, in order. Never sends two at the same time.
 * - success / duplicate: removed from the queue
 * - no connection: stop, keep the rest for later
 * - refused by the server: marked failed with the reason; the following ones are tried too
 *   (the server refuses them if the order no longer fits, and they get their own reason)
 * - not_authenticated: stop (the caller signs the user out; the queue stays saved)
 */
export async function syncQueue(
  queue: QueuedPunch[],
  send: (input: OfflinePunchInput) => Promise<PunchResult>,
  now: () => number = Date.now,
): Promise<SyncResult> {
  const out: QueuedPunch[] = queue.map((q) => ({ ...q }));
  const done = new Set<string>();
  const sent: PunchResult[] = [];
  const refused: QueuedPunch[] = [];
  let stoppedOffline = false;

  for (const item of out) {
    if (item.status !== "pending") continue;
    try {
      sent.push(await send(toOfflineInput(item, now())));
      done.add(item.request_id);
    } catch (e) {
      const code: AppErrorCode = e instanceof AppError ? e.code : toKnownCode(String(e));
      if (code === "network") {
        stoppedOffline = true;
        break;
      }
      if (code === "not_authenticated") throw e;
      item.status = "failed";
      item.error_code = code;
      refused.push(item);
    }
  }

  return { queue: out.filter((q) => !done.has(q.request_id)), sent, refused, stoppedOffline };
}
