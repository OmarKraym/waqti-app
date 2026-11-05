// First-run setup on this phone: location, fingerprint / Face ID, notifications.
// Pure helpers (unit-tested); the screen is screens/PermissionsSetup.tsx. Nothing here throws.
import type { BiometricState } from "./biometric";
import { fromB64u, keysOf, VAPID_PUBLIC_KEY, type SubscriptionKeys } from "./push";

export type Os = "ios" | "android" | "other";
export interface DeviceInfo {
  os: Os;
  osVersion: string | null;
  browser: string;
  /** Opened inside another app (Facebook, Instagram, Android WebView…): WebAuthn usually does not work there. */
  inApp: string | null;
}

/** What the user agent says about the phone. Chrome on Android hides the phone model ("Android 10; K"). */
export function deviceInfo(ua: string): DeviceInfo {
  const ios = /iPhone|iPad|iPod/i.test(ua);
  const android = /Android/i.test(ua);
  const iv = ua.match(/OS (\d+)[_.](\d+)/);
  const av = ua.match(/Android (\d+(?:\.\d+)?)/);
  const inApp =
    /FBAN|FBAV|FB_IAB/.test(ua) ? "Facebook"
    : /Instagram/.test(ua) ? "Instagram"
    : /\bLine\//.test(ua) ? "Line"
    : /Snapchat/.test(ua) ? "Snapchat"
    : /WhatsApp/i.test(ua) ? "WhatsApp"
    : /Telegram/i.test(ua) ? "Telegram"
    : /\bGSA\//.test(ua) ? "Google"
    : android && /; wv\)/.test(ua) ? "WebView"
    : null;
  const browser =
    /MiuiBrowser/.test(ua) ? "Mi Browser"
    : /SamsungBrowser/.test(ua) ? "Samsung Internet"
    : /CriOS|Chrome\//.test(ua) ? "Chrome"
    : /FxiOS|Firefox\//.test(ua) ? "Firefox"
    : /EdgiOS|EdgA\//.test(ua) ? "Edge"
    : ios || /Safari\//.test(ua) ? "Safari"
    : "?";
  return {
    os: ios ? "ios" : android ? "android" : "other",
    osVersion: ios && iv ? `${iv[1]}.${iv[2]}` : android && av ? av[1] : null,
    browser,
    inApp,
  };
}

export interface BioEnv {
  ua: string;
  /** window.isSecureContext */
  secure: boolean;
  /** window.PublicKeyCredential exists */
  hasWebAuthn: boolean;
  /** isUserVerifyingPlatformAuthenticatorAvailable(); null when it could not be asked */
  platformAuth: boolean | null;
  standalone?: boolean;
}

export type BioReason = "insecure" | "in_app" | "old_ios" | "no_webauthn" | "no_lock_ios" | "no_lock_android";

/** The most likely reason why the phone says it cannot do fingerprint / Face ID. */
export function bioReason(e: BioEnv): BioReason {
  const d = deviceInfo(e.ua);
  if (!e.secure) return "insecure";
  if (d.inApp) return "in_app";
  if (!e.hasWebAuthn) return d.os === "ios" && d.osVersion !== null && Number(d.osVersion.split(".")[0]) < 14 ? "old_ios" : "no_webauthn";
  return d.os === "ios" ? "no_lock_ios" : "no_lock_android";
}

export const BIO_HELP: Record<BioReason, string> = {
  insecure: "افتح التطبيق من رابطه الرسمي (يبدأ بـ https) أو من أيقونته في الشاشة الرئيسية.",
  in_app: "فتحت التطبيق من داخل تطبيق آخر (مثل واتساب أو فيسبوك أو إنستغرام)، والبصمة لا تعمل هناك. افتحه من Safari في الآيفون أو Chrome في الأندرويد، أو من أيقونته في الشاشة الرئيسية.",
  old_ios: "نظام الهاتف قديم ولا يدعم البصمة في المتصفح. حدّث iOS من: الإعدادات ← عام ← تحديث البرنامج.",
  no_webauthn: "هذا المتصفح لا يدعم البصمة. افتح التطبيق من Safari في الآيفون أو Chrome في الأندرويد.",
  no_lock_ios: "فعّل Face ID (أو Touch ID) ورمز الدخول في الهاتف: الإعدادات ← Face ID ورمز الدخول. ثم ارجع واضغط «أعد الفحص».",
  no_lock_android: "فعّل قفل الشاشة والبصمة في الهاتف: الإعدادات ← الأمان ← قفل الشاشة / بصمة الإصبع. ثم ارجع واضغط «أعد الفحص».",
};

const yesNo = (v: boolean | null | undefined) => (v === null || v === undefined ? "؟" : v ? "نعم" : "لا");

/** One short line the employee can send to the admin (a screenshot is enough). */
export function diagLine(e: BioEnv): string {
  const d = deviceInfo(e.ua);
  const os = d.os === "ios" ? "iOS" : d.os === "android" ? "Android" : "?";
  return [
    `${os} ${d.osVersion ?? "?"}`,
    d.inApp ? `${d.browser} داخل ${d.inApp}` : d.browser,
    `من الشاشة الرئيسية: ${yesNo(e.standalone)}`,
    `WebAuthn: ${yesNo(e.hasWebAuthn)}`,
    `قفل/بصمة: ${yesNo(e.platformAuth)}`,
  ].join(" · ");
}

export type PermState = "granted" | "denied" | "prompt" | "unknown";
type PermQuery = { query: (d: { name: "geolocation" }) => Promise<{ state: string }> };

/** The location permission, read WITHOUT asking. "unknown" when the browser cannot tell (the tap will ask). */
export async function geoPermission(perms: PermQuery | undefined = globalThis.navigator?.permissions as PermQuery | undefined): Promise<PermState> {
  try {
    if (!perms?.query) return "unknown";
    const s = (await perms.query({ name: "geolocation" })).state;
    return s === "granted" || s === "denied" || s === "prompt" ? s : "unknown";
  } catch {
    return "unknown";
  }
}

/** Where a "no" for the location comes from on Android (Chrome's own per-site setting, or the phone refusing Chrome). */
export interface GeoContext {
  /** "chrome": Chrome's site setting says denied (also after 3 dismissed prompts Chrome blocks by itself for days).
   *  "phone": Chrome would allow the site, but Android does not give Chrome the location. */
  blockedBy?: "chrome" | "phone";
  /** Installed on the home screen: no address bar, so no lock icon to tap. */
  standalone?: boolean;
  host?: string;
}

const CHROME_SITE = (host: string) =>
  `١. افتح تطبيق Chrome ← ⋮ (أعلى الشاشة) ← الإعدادات ← إعدادات المواقع ← الموقع.\n`
  + `٢. فعّل «الموقع» إن كان مطفأً.\n`
  + `٣. في قائمة «غير مسموح» اضغط ${host} واختر «سماح».`;
const PHONE_CHROME =
  "إعدادات الهاتف ← التطبيقات ← Chrome ← الأذونات ← الموقع ← «السماح أثناء استخدام التطبيق»، وفعّل «استخدام الموقع الدقيق».\n"
  + "في شاومي وريدمي وبوكو: الإعدادات ← التطبيقات ← إدارة التطبيقات ← Chrome ← أذونات التطبيق ← الموقع ← «السماح أثناء الاستخدام».";

/**
 * What to do when the phone gave no position. Once Chrome blocks the location it never asks again by itself.
 * An app installed on the home screen keeps its permissions in Chrome's site settings (not in the app's Android page).
 */
export function geoHelp(kind: "ok" | "denied" | "unavailable" | "timeout" | "unsupported" | "not_requested", os: Os,
                        ctx: GeoContext = {}): string | null {
  if (kind === "ok" || kind === "not_requested") return null;
  if (kind === "denied") {
    if (os === "ios") {
      return "الموقع ممنوع لهذا التطبيق. افتح: الإعدادات ← الخصوصية والأمان ← خدمات الموقع، وشغّلها. ثم اختر Safari (أو المتصفح الذي تستخدمه) ← «أثناء استخدام التطبيق». ارجع واضغط «السماح بالموقع».";
    }
    const host = ctx.host ?? "موقع وقتي";
    if (ctx.blockedBy === "phone") {
      return `Chrome يسمح لوقتي، لكن الهاتف لا يعطي Chrome الموقع:\n${PHONE_CHROME}\nثم ارجع واضغط «السماح بالموقع».`;
    }
    const chrome = ctx.standalone === false
      ? `اضغط القفل (أو ⓘ) بجانب الرابط ← الأذونات ← الموقع ← سماح.\nأو:\n${CHROME_SITE(host)}`
      : CHROME_SITE(host);
    if (ctx.blockedBy === "chrome") {
      return `Chrome يمنع الموقع عن وقتي (الإعداد داخل Chrome، وليس في إعدادات الهاتف):\n${chrome}\nإن كان مسموحًا هناك: ${PHONE_CHROME}\nثم ارجع هنا.`;
    }
    return `الموقع ممنوع لهذا التطبيق، والهاتف لن يسأل مرة أخرى بنفسه:\n${chrome}\nإن بقي ممنوعًا: ${PHONE_CHROME}\nثم ارجع واضغط «السماح بالموقع».`;
  }
  if (kind === "timeout") return "لم نصل إلى موقعك. شغّل GPS (الموقع) من الإعدادات السريعة، وانتقل إلى مكان مفتوح، ثم اضغط مرة أخرى.";
  return "شغّل GPS (الموقع) من الإعدادات السريعة في الهاتف، ثم اضغط مرة أخرى.";
}

/** This page in a normal Chrome tab (Android): it has the address bar and its lock, where the site's permissions are. */
export function chromeTabUrl(href: string): string {
  const u = new URL(href);
  return `intent://${u.host}${u.pathname}${u.search}#Intent;scheme=https;package=com.android.chrome;end`;
}

/** After sign-in: the setup screen comes first when the phone must still be registered, or the first time on this phone. */
export function setupGate(b: BiometricState | undefined, seen: boolean): "setup" | "home" {
  const mustRegister = !!b && b.policy === "required" && !b.has_device;
  return mustRegister || !seen ? "setup" : "home";
}

type Store = Pick<Storage, "getItem" | "setItem">;
const SEEN_KEY = (userId: string) => `waqti-setup-seen:${userId}`;
function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}
export function setupSeen(userId: string, store: Store | null = defaultStore()): boolean {
  try {
    return store?.getItem(SEEN_KEY(userId)) === "1";
  } catch {
    return false;
  }
}
export function markSetupSeen(userId: string, store: Store | null = defaultStore()): void {
  try {
    store?.setItem(SEEN_KEY(userId), "1");
  } catch {
    /* blocked storage: the setup shows again next time, nothing worse */
  }
}

type PushManagerLike = {
  getSubscription: () => Promise<{ endpoint: string; toJSON: () => unknown } | null>;
  subscribe: (o: { userVisibleOnly: boolean; applicationServerKey: Uint8Array<ArrayBuffer> }) => Promise<{ endpoint: string; toJSON: () => unknown }>;
};

/**
 * On every app start: if notifications are ALLOWED on this phone, make sure it is still subscribed (a lost subscription,
 * e.g. after the browser cleared it, is renewed). Never asks for permission by itself. Returns the keys to save, or null.
 */
export async function ensureSubscription(deps: { permission: NotificationPermission | "unsupported"; pushManager: PushManagerLike | null }): Promise<SubscriptionKeys | null> {
  try {
    if (deps.permission !== "granted" || !deps.pushManager) return null;
    const sub = (await deps.pushManager.getSubscription())
      ?? (await deps.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromB64u(VAPID_PUBLIC_KEY) }));
    return keysOf(sub as PushSubscription);
  } catch {
    return null;
  }
}
