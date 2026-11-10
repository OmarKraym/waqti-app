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
import type { Calendar } from "./calendar";
import { getDeviceKey } from "./deviceKey";
import { SIGNOUT_REASON_KEY } from "./signoutReason";
import { AppError, toKnownCode } from "./errors";
import type {
  AttendanceState,
  InboxItem,
  NewRequest,
  NotificationSettings,
  OvertimeItem,
  OvertimeOverview,
  OvertimePreview,
  OfflinePunchInput,
  PunchInput,
  LateStatus,
  PunchResult,
  RequestItem,
  RequestPreview,
  RequestsOverview,
  ProfileSummary,
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

  /** Binds this session to this phone. Kept here so any call that meets "device_not_bound" can bind and retry once. */
  async function bind(): Promise<void> {
    const key = getDeviceKey();
    if (!key) throw new AppError("device_locked", "no_storage");
    try {
      await rpc<unknown>("employee_bind_device", { p_key: key, p_user_agent: navigator.userAgent.slice(0, 300) }, true);
    } catch (e) {
      // The server does not have the phone lock yet (app updated before the database): nothing to bind.
      if (e instanceof AppError && e.code === "unknown" && /Could not find the function|employee_bind_device/.test(e.message)) return;
      throw e;
    }
  }
  /** The phone is not (or no longer) this account's phone: end the session and tell the sign-in screen why. */
  async function lockedOut(code: "device_locked" | "login_again"): Promise<never> {
    try {
      sessionStorage.setItem(SIGNOUT_REASON_KEY, code);
    } catch {
      /* blocked storage: the sign-in screen just shows no reason */
    }
    await sb.auth.signOut().catch(() => undefined);
    throw new AppError(code);
  }

  async function rpc<T>(fn: string, args?: Record<string, unknown>, noRebind = false): Promise<T> {
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
    if (result.error) {
      const err = fromPostgrest(result.error);
      // A session that is not bound yet (e.g. right after the update, or after a token refresh into a new session):
      // bind this phone and try the call once more. Another phone, or an unbound account, ends the session.
      if (err.code === "device_not_bound" && !noRebind) {
        try {
          await bind();
        } catch (e) {
          if (e instanceof AppError && (e.code === "device_locked" || e.code === "login_again")) return lockedOut(e.code);
          throw e;
        }
        return rpc<T>(fn, args, true);
      }
      throw err;
    }
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

    async signInWithToken(tokenHash) {
      // The token comes from generateLink; Supabase names its type "magiclink" (older) or "email" (newer).
      let last: { name?: string; status?: number } | null = null;
      for (const type of ["magiclink", "email"] as const) {
        const { error } = await sb.auth.verifyOtp({ token_hash: tokenHash, type });
        if (!error) return;
        if (error.name === "AuthRetryableFetchError" || error.status === 0) throw new AppError("network");
        last = error;
      }
      throw new AppError("biometric_failed", last?.name);
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

    async bindDevice() {
      try {
        await bind();
      } catch (e) {
        // After an unbind an old session must sign in again; another phone (device_locked) gets its own screen.
        if (e instanceof AppError && e.code === "login_again") return lockedOut("login_again");
        throw e;
      }
    },

    async getCalendar() {
      try {
        return await rpc<Calendar>("employee_calendar");
      } catch (e) {
        if (e instanceof AppError && e.code === "unknown" && /Could not find the function|employee_calendar/.test(e.message)) return null;
        throw e;
      }
    },

    getProfileSummary() {
      return rpc<ProfileSummary>("employee_profile_summary");
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
        p_biometric: input.biometric ?? "ticket",
      });
    },

    async webauthn(action, body) {
      const { data, error } = await sb.functions.invoke("webauthn", { body: { action, ...(body ?? {}) } });
      if (error) {
        if (error instanceof FunctionsFetchError) throw new AppError("network");
        if (error instanceof FunctionsHttpError) {
          const res = await (error.context as Response).json().catch(() => null);
          throw new AppError(toKnownCode(res?.error), res?.error);
        }
        throw new AppError("unknown", error.message);
      }
      return data;
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

    async getLateStatus(eventId: string) {
      try {
        return await rpc<LateStatus>("employee_late_status", { p_event_id: eventId });
      } catch (e) {
        // Offline, or the app was updated before the database: no decision to show. Every other error is the caller's.
        if (e instanceof AppError && e.code === "network") return null;
        if (e instanceof AppError && e.code === "unknown" && /Could not find the function|employee_late_status/.test(e.message)) return null;
        throw e;
      }
    },

    async getRequestsOverview() {
      // The leave rule comes from a newer database function; without it the screen keeps the old limits.
      const [overview, win] = await Promise.all([
        rpc<RequestsOverview>("employee_requests_overview"),
        rpc<{ earliest: string }>("employee_leave_window").catch(() => null),
      ]);
      return win?.earliest ? { ...overview, leave_earliest: win.earliest } : overview;
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

    getOvertimeOverview() {
      return rpc<OvertimeOverview>("employee_overtime_overview");
    },

    previewOvertime(i) {
      return rpc<OvertimePreview>("manager_assign_overtime", {
        p_assign_key: PREVIEW_KEY, p_employee_id: i.employee_id, p_start_at: i.start_at, p_end_at: i.end_at, p_task: i.task, p_dry_run: true,
      });
    },

    assignOvertime(key, i) {
      return rpc<OvertimeItem>("manager_assign_overtime", {
        p_assign_key: key, p_employee_id: i.employee_id, p_start_at: i.start_at, p_end_at: i.end_at, p_task: i.task, p_dry_run: false,
      });
    },

    cancelOvertime(id) {
      return rpc<OvertimeItem>("manager_cancel_overtime", { p_id: id });
    },

    noteOvertime(id, note) {
      return rpc<OvertimeItem>("employee_overtime_note", { p_id: id, p_note: note });
    },
  };
}

/** A preview saves nothing, so its key is never stored. */
const PREVIEW_KEY = "00000000-0000-4000-8000-000000000000";

/** Arguments of employee_submit_request (dates for leave/other, instants for permission). */
export function submitArgs(key: string, r: NewRequest, dryRun: boolean): Record<string, unknown> {
  const args: Record<string, unknown> = {
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
  // Sent only for a kind the administration added: a database before phase 24 does not know the parameter,
  // so built-in requests must not carry it.
  if (r.type !== "permission" && r.custom_kind_id) args.p_custom_kind_id = r.custom_kind_id;
  return args;
}
