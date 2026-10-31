import {
  createClient,
  isAuthRetryableFetchError,
  FunctionsFetchError,
  FunctionsHttpError,
  type PostgrestError,
  type SupabaseClient,
  type User,
} from "@supabase/supabase-js";
import type { SessionUser, WaqtiApi } from "./api";
import { AppError, toKnownCode } from "./errors";
import type {
  AttendanceState,
  InboxItem,
  NewRequest,
  NotificationSettings,
  OfflinePunchInput,
  PunchInput,
  PunchResult,
  RequestItem,
  RequestPreview,
  RequestsOverview,
} from "./types";

const REQUEST_TIMEOUT_MS = 15_000;
/** Longest wait for the saved login at app start before falling back to the copy on the phone. */
const SESSION_WAIT_MS = 4_000;
/** Whole request including a token refresh. A timeout counts as "no answer" (outcome unknown). */
const RPC_TIMEOUT_MS = 25_000;

/**
 * fetch with a hard timeout, so a dead connection never leaves the button spinning forever.
 * Uses only AbortController + setTimeout (AbortSignal.any / .timeout are missing on older iPhones).
 */
export function fetchWithTimeout(
  input: RequestInfo | URL,
  init?: RequestInit,
  timeoutMs: number = REQUEST_TIMEOUT_MS,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const outer = init?.signal;
  if (outer) {
    if (outer.aborted) controller.abort();
    else outer.addEventListener("abort", () => controller.abort(), { once: true });
  }
  return fetch(input, { ...init, signal: controller.signal }).finally(() => clearTimeout(timer));
}

function toSessionUser(user: User): SessionUser {
  return {
    id: user.id,
    email: user.email ?? null,
    // app_metadata can only be changed by the server, but the server still enforces this itself.
    mustChangePassword: user.app_metadata?.must_change_password === true,
  };
}

/**
 * Database errors -> AppError.
 * Server functions raise their reason as the exception message (e.g. 'outside_geofence', SQLSTATE P0001).
 * An error with no SQLSTATE code means the request did not get a database answer (network, timeout).
 */
export function fromPostgrest(error: Pick<PostgrestError, "code" | "message">): AppError {
  if (!error.code) return new AppError("network", error.message);
  if (error.code === "PGRST301" || error.code === "PGRST303") return new AppError("not_authenticated");
  // The server's own reason comes first: account errors (employee_inactive, must_change_password,
  // not_authenticated) are raised with SQLSTATE 42501 too, and must not all become "forbidden".
  const known = toKnownCode(error.message);
  if (known !== "unknown") return new AppError(known, error.message);
  if (error.code === "42501") return new AppError("forbidden", error.message);
  return new AppError("unknown", error.message);
}

/** Same key supabase-js uses by default: sb-<project ref>-auth-token. */
export function authStorageKey(url: string): string {
  return `sb-${new URL(url).hostname.split(".")[0]}-auth-token`;
}

/**
 * The user saved on this phone, read straight from storage.
 * Used ONLY when the app opens with no internet and the 1-hour access token has expired: supabase-js
 * then cannot refresh it and reports "no session", although the employee never logged out.
 * Nothing is trusted from this on the server: every request still needs a valid token, which
 * supabase-js gets again as soon as the connection is back.
 */
export function storedSessionUser(storage: Pick<Storage, "getItem"> | null, storageKey: string): SessionUser | null {
  if (!storage) return null;
  try {
    const raw = storage.getItem(storageKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { user?: User | null; refresh_token?: string };
    let user = parsed.user ?? null;
    if (!user) {
      const rawUser = storage.getItem(`${storageKey}-user`);
      user = rawUser ? ((JSON.parse(rawUser) as { user?: User }).user ?? null) : null;
    }
    return user && parsed.refresh_token ? toSessionUser(user) : null;
  } catch {
    return null;
  }
}

function safeLocalStorage(): Storage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function createSupabaseApi(url: string, key: string): WaqtiApi {
  const sb: SupabaseClient = createClient(url, key, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
    global: { fetch: fetchWithTimeout },
  });

  async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
    // No connection: fail at once. Otherwise supabase-js first waits for its token refresh, which
    // retries for a long time offline, and the screen would hang instead of using the saved state.
    if (!navigator.onLine) throw new AppError("network", "offline");
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new AppError("network", "timeout")), RPC_TIMEOUT_MS);
    });
    let result;
    try {
      result = await Promise.race([sb.rpc(fn, args), timeout]);
    } catch (e) {
      throw e instanceof AppError ? e : new AppError("network", String(e));
    } finally {
      clearTimeout(timer);
    }
    if (result.error) throw fromPostgrest(result.error);
    return result.data as T;
  }

  return {
    async getSessionUser() {
      const stored = () => storedSessionUser(safeLocalStorage(), authStorageKey(url));
      // No internet: do not wait for supabase-js. With an expired access token it keeps retrying the
      // refresh (long backoff), and the app would stay on a blank screen. Use the login saved here.
      if (!navigator.onLine) {
        const user = stored();
        if (user) return user;
      }
      type Result = { data: { session: { user: User } | null }; error?: unknown };
      const timeout = new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), SESSION_WAIT_MS));
      const result: Result | "timeout" = await Promise.race([
        sb.auth.getSession().then(
          (r) => r as Result,
          (e) => ({ data: { session: null }, error: e }) as Result,
        ),
        timeout,
      ]);
      // Too slow (bad connection): same as offline.
      if (result === "timeout") return stored();
      if (result.data.session) return toSessionUser(result.data.session.user);
      // Offline with an expired access token: keep the employee signed in on this phone.
      const offline = !navigator.onLine || isAuthRetryableFetchError(result.error);
      return offline ? stored() : null;
    },

    onAuthChange(cb) {
      const { data } = sb.auth.onAuthStateChange(() => cb());
      return () => data.subscription.unsubscribe();
    },

    async signIn(email, password) {
      const { error } = await sb.auth.signInWithPassword({ email, password });
      if (!error) return;
      if (error.name === "AuthRetryableFetchError" || error.status === 0) throw new AppError("network");
      if (error.code === "invalid_credentials" || error.status === 400) throw new AppError("invalid_credentials");
      throw new AppError("unknown", error.message);
    },

    async signOut() {
      // "local" ends the session on this device only.
      await sb.auth.signOut({ scope: "local" });
    },

    async changeTemporaryPassword(newPassword) {
      const { error } = await sb.functions.invoke("change-password", { body: { new_password: newPassword } });
      if (error) {
        if (error instanceof FunctionsFetchError) throw new AppError("network");
        if (error instanceof FunctionsHttpError) {
          const body = await (error.context as Response).json().catch(() => null);
          throw new AppError(toKnownCode(body?.error), body?.error);
        }
        throw new AppError("unknown", error.message);
      }
      // The server cleared must_change_password; get a token that shows it.
      const { error: refreshError } = await sb.auth.refreshSession();
      if (refreshError) throw new AppError("not_authenticated");
    },

    getAttendanceState() {
      return rpc<AttendanceState>("employee_attendance_state");
    },

    punch(input: PunchInput) {
      const r = input.reading;
      return rpc<PunchResult>("employee_punch", {
        p_request_id: input.request_id,
        p_expected_action: input.expected_action,
        p_reading: r.kind,
        p_lat: r.kind === "ok" ? r.lat : null,
        p_lng: r.kind === "ok" ? r.lng : null,
        p_accuracy_m: r.kind === "ok" ? r.accuracy_m : null,
      });
    },

    punchOffline(input: OfflinePunchInput) {
      const r = input.reading;
      return rpc<PunchResult>("employee_punch_offline", {
        p_request_id: input.request_id,
        p_expected_action: input.expected_action,
        p_reading: r.kind,
        p_lat: r.kind === "ok" ? r.lat : null,
        p_lng: r.kind === "ok" ? r.lng : null,
        p_accuracy_m: r.kind === "ok" ? r.accuracy_m : null,
        p_time_token: input.time_token,
        p_token_device_time: input.token_device_time,
        p_device_time: input.device_time,
        p_monotonic_ms: input.monotonic_ms,
        p_device_now: input.device_now,
      });
    },

    getRequestsOverview() {
      return rpc<RequestsOverview>("employee_requests_overview");
    },

    previewRequest(request) {
      return rpc<RequestPreview>("employee_submit_request", submitArgs(PREVIEW_KEY, request, true));
    },

    submitRequest(key, request) {
      return rpc<RequestItem>("employee_submit_request", submitArgs(key, request, false));
    },

    cancelRequest(id) {
      return rpc<RequestItem>("employee_cancel_request", { p_request_id: id });
    },

    getInbox() {
      return rpc<InboxItem[]>("approver_inbox");
    },

    decide(approvalId, decision, note) {
      return rpc<RequestItem>("approver_decide", { p_approval_id: approvalId, p_decision: decision, p_note: note });
    },

    async savePushSubscription(k) {
      await rpc<null>("employee_save_push_subscription", {
        p_endpoint: k.endpoint, p_p256dh: k.p256dh, p_auth: k.auth, p_user_agent: navigator.userAgent.slice(0, 300),
      });
    },

    async deletePushSubscription(endpoint) {
      await rpc<null>("employee_delete_push_subscription", { p_endpoint: endpoint });
    },

    getNotificationSettings() {
      return rpc<NotificationSettings>("employee_get_notification_settings");
    },

    setNotificationSettings(s) {
      return rpc<NotificationSettings>("employee_set_notification_settings", {
        p_remind_check_in: s.remind_check_in, p_check_in_before: s.check_in_before,
        p_remind_check_out: s.remind_check_out, p_check_out_before: s.check_out_before,
      });
    },

    async testNotification() {
      await rpc<null>("employee_test_notification");
    },
  };
}

/** A preview saves nothing, so its key is never stored. */
const PREVIEW_KEY = "00000000-0000-4000-8000-000000000000";

/** Arguments of employee_submit_request (dates for leave/other, instants for permission). */
export function submitArgs(key: string, r: NewRequest, dryRun: boolean): Record<string, unknown> {
  return {
    p_request_key: key,
    p_type: r.type,
    p_leave_type: r.type === "leave" ? r.leave_type : null,
    p_start_date: r.type === "permission" ? null : r.start_date,
    p_end_date: r.type === "permission" ? null : r.end_date,
    p_start_at: r.type === "permission" ? r.start_at : null,
    p_end_at: r.type === "permission" ? r.end_at : null,
    p_reason: r.reason,
    p_dry_run: dryRun,
    p_permission_type_id: r.type === "permission" ? r.permission_type_id : null,
  };
}
