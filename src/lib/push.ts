// Web Push on this device: support, permission, subscribe / unsubscribe.
// The server sends everything (requests, decisions, reminders); the phone only subscribes.
// iPhone/iPad: push works only in the INSTALLED app (Home Screen), iOS 16.4 or later.

/** Public VAPID key of the Waqti server (the private key is only in the send-push function). */
export const VAPID_PUBLIC_KEY = "BNbXYZsn528LZfRVneQdnByePgcSID-rY3SrVhUq97rN3hS80kfyOC_3v3nV4SHQT4DxCCRJ8jZAV-5nI-ZE24g";

export type PushState =
  | "unsupported"        // this browser has no Web Push
  | "ios_install"        // iPhone/iPad in Safari: install the app first
  | "denied"             // the user blocked notifications for this app
  | "off"                // can be turned on
  | "on";                // subscribed on this device

interface Env {
  hasPush: boolean;
  isIos: boolean;
  standalone: boolean;
  permission: NotificationPermission | "unsupported";
  subscribed: boolean;
}

/** Pure decision (unit-tested). */
export function pushState(e: Env): PushState {
  if (e.isIos && !e.standalone) return "ios_install";
  if (!e.hasPush || e.permission === "unsupported") return "unsupported";
  if (e.permission === "denied") return "denied";
  return e.subscribed && e.permission === "granted" ? "on" : "off";
}

export function fromB64u(s: string): Uint8Array<ArrayBuffer> {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function env(): Omit<Env, "subscribed"> {
  const ua = navigator.userAgent;
  const isIos = /iPad|iPhone|iPod/.test(ua) || (ua.includes("Macintosh") && navigator.maxTouchPoints > 1);
  const standalone =
    window.matchMedia?.("(display-mode: standalone)").matches ||
    (navigator as Navigator & { standalone?: boolean }).standalone === true;
  const hasPush = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  return { hasPush, isIos, standalone, permission: "Notification" in window ? Notification.permission : "unsupported" };
}

async function registration(): Promise<ServiceWorkerRegistration | null> {
  if (!("serviceWorker" in navigator)) return null;
  const timeout = new Promise<null>((r) => setTimeout(() => r(null), 8000));
  return Promise.race([navigator.serviceWorker.ready, timeout]);
}

export async function currentSubscription(): Promise<PushSubscription | null> {
  const e = env();
  if (!e.hasPush) return null;
  const reg = await registration();
  return reg ? reg.pushManager.getSubscription() : null;
}

export async function readPushState(): Promise<PushState> {
  const e = env();
  const subscribed = e.hasPush && e.permission === "granted" ? (await currentSubscription()) !== null : false;
  return pushState({ ...e, subscribed });
}

export interface SubscriptionKeys {
  endpoint: string;
  p256dh: string;
  auth: string;
}

export function keysOf(sub: PushSubscription): SubscriptionKeys {
  const j = sub.toJSON() as { endpoint?: string; keys?: { p256dh?: string; auth?: string } };
  return { endpoint: j.endpoint ?? sub.endpoint, p256dh: j.keys?.p256dh ?? "", auth: j.keys?.auth ?? "" };
}

/** Asks permission (must be called from a tap) and subscribes. Returns the keys to save on the server. */
export async function subscribe(): Promise<SubscriptionKeys> {
  const permission = await Notification.requestPermission();
  if (permission !== "granted") throw new Error(permission === "denied" ? "denied" : "dismissed");
  const reg = await registration();
  if (!reg) throw new Error("no_service_worker");
  const existing = await reg.pushManager.getSubscription();
  const sub = existing ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromB64u(VAPID_PUBLIC_KEY) }));
  return keysOf(sub);
}

/** Unsubscribes this device. Returns the endpoint to remove on the server (or null). */
export async function unsubscribe(): Promise<string | null> {
  const sub = await currentSubscription();
  if (!sub) return null;
  const endpoint = sub.endpoint;
  await sub.unsubscribe().catch(() => undefined);
  return endpoint;
}
