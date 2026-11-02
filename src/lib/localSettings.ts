// The employee's settings are kept on the phone as well, so they are still there after an app update, with no
// connection, and while the server is slow. localStorage is not touched by an update of the app (only the cached
// app files are replaced); the keys below are never renamed or cleared by the app. Nothing here ever throws:
// storage can be blocked (private mode), and the app must work without it.
import type { NotificationSettings } from "./types";

type Store = Pick<Storage, "getItem" | "setItem">;
/** What is kept: the choices only. `devices` is a fact about the server, so it is not stored. */
export type NotificationPrefs = Omit<NotificationSettings, "devices">;

const KEY = (userId: string) => `waqti-notif:${userId}`;
export const NOTIFICATION_BEFORE_MAX = 240;

function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

const isMinutes = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= NOTIFICATION_BEFORE_MAX;

/** The saved reminder choices of this user, or null when nothing valid is saved (anything odd is ignored). */
export function readNotificationPrefs(userId: string, store: Store | null = defaultStore()): NotificationPrefs | null {
  try {
    const raw = store?.getItem(KEY(userId));
    if (!raw) return null;
    const v = JSON.parse(raw) as Record<string, unknown>;
    if (typeof v.remind_check_in !== "boolean" || typeof v.remind_check_out !== "boolean"
        || !isMinutes(v.check_in_before) || !isMinutes(v.check_out_before)) return null;
    return { remind_check_in: v.remind_check_in, check_in_before: v.check_in_before, remind_check_out: v.remind_check_out, check_out_before: v.check_out_before };
  } catch {
    return null;
  }
}

export function saveNotificationPrefs(userId: string, s: NotificationPrefs, store: Store | null = defaultStore()): void {
  try {
    const { remind_check_in, check_in_before, remind_check_out, check_out_before } = s;
    store?.setItem(KEY(userId), JSON.stringify({ remind_check_in, check_in_before, remind_check_out, check_out_before }));
  } catch {
    /* blocked or full storage: the server still has the settings */
  }
}

/** Asks the browser not to delete this site's saved data when the phone runs low on space. Silent; may be refused. */
export async function keepStorage(): Promise<boolean> {
  try {
    if (typeof navigator === "undefined" || !navigator.storage?.persist) return false;
    return (await navigator.storage.persisted?.()) || (await navigator.storage.persist());
  } catch {
    return false;
  }
}

const EMAIL_KEY = "waqti-last-email";

/** The email used last on this phone, to pre-fill the sign-in form. Not a secret. Null when nothing valid is saved. */
export function readLastEmail(store: Store | null = defaultStore()): string | null {
  try {
    const v = store?.getItem(EMAIL_KEY);
    return v && isEmail(v) ? v : null;
  } catch {
    return null;
  }
}

export function saveLastEmail(email: string, store: Store | null = defaultStore()): void {
  try {
    const v = email.trim().toLowerCase();
    if (isEmail(v)) store?.setItem(EMAIL_KEY, v);
  } catch {
    /* blocked storage: the form is just not pre-filled next time */
  }
}

const isEmail = (v: string) => v.length <= 254 && /^[^\s@]+@[^\s@]+$/.test(v);
