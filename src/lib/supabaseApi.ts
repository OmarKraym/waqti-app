import {
  createClient,
  FunctionsFetchError,
  FunctionsHttpError,
  type PostgrestError,
  type SupabaseClient,
  type User,
} from "@supabase/supabase-js";
import type { SessionUser, WaqtiApi } from "./api";
import { AppError, toKnownCode } from "./errors";
import type { AttendanceState, PunchInput, PunchResult } from "./types";

const REQUEST_TIMEOUT_MS = 15_000;

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

export function createSupabaseApi(url: string, key: string): WaqtiApi {
  const sb: SupabaseClient = createClient(url, key, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
    global: { fetch: fetchWithTimeout },
  });

  async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
    let result;
    try {
      result = await sb.rpc(fn, args);
    } catch (e) {
      throw new AppError("network", String(e));
    }
    if (result.error) throw fromPostgrest(result.error);
    return result.data as T;
  }

  return {
    async getSessionUser() {
      const { data } = await sb.auth.getSession();
      return data.session ? toSessionUser(data.session.user) : null;
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
  };
}
