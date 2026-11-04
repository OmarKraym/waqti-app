import { describe, expect, it, vi } from "vitest";
import {
  bioReason, BIO_HELP, deviceInfo, diagLine, geoHelp, geoPermission, markSetupSeen, setupGate, setupSeen, ensureSubscription,
} from "./permissions";

const UA = {
  iphone17: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
  iphone13: "Mozilla/5.0 (iPhone; CPU iPhone OS 13_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1 Mobile/15E148 Safari/604.1",
  iphoneFb: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/450.0]",
  iphoneInsta: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 350.0",
  iphoneChrome: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0 Mobile/15E148 Safari/604.1",
  android: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
  androidWebView: "Mozilla/5.0 (Linux; Android 13; SM-A515F; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/130.0 Mobile Safari/537.36",
  miBrowser: "Mozilla/5.0 (Linux; U; Android 12; Redmi Note 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0 Mobile Safari/537.36 XiaoMi/MiuiBrowser/17.5",
};

describe("deviceInfo: what the user agent says about the phone", () => {
  it("iPhone Safari with its iOS version", () => {
    expect(deviceInfo(UA.iphone17)).toMatchObject({ os: "ios", osVersion: "17.2", browser: "Safari", inApp: null });
  });
  it("in-app browsers are named", () => {
    expect(deviceInfo(UA.iphoneFb).inApp).toBe("Facebook");
    expect(deviceInfo(UA.iphoneInsta).inApp).toBe("Instagram");
    expect(deviceInfo(UA.androidWebView).inApp).toBe("WebView");
  });
  it("other browsers", () => {
    expect(deviceInfo(UA.iphoneChrome).browser).toBe("Chrome");
    expect(deviceInfo(UA.android)).toMatchObject({ os: "android", osVersion: "10", browser: "Chrome", inApp: null });
    expect(deviceInfo(UA.miBrowser).browser).toBe("Mi Browser");
  });
});

describe("bioReason: why the phone says it has no fingerprint / Face ID", () => {
  const base = { ua: UA.iphone17, secure: true, hasWebAuthn: true, platformAuth: false };
  it("page not on https", () => expect(bioReason({ ...base, secure: false })).toBe("insecure"));
  it("opened inside Facebook / WhatsApp-like app", () => expect(bioReason({ ...base, ua: UA.iphoneFb })).toBe("in_app"));
  it("very old iOS without WebAuthn", () => expect(bioReason({ ...base, ua: UA.iphone13, hasWebAuthn: false })).toBe("old_ios"));
  it("browser without WebAuthn", () => expect(bioReason({ ...base, ua: UA.miBrowser, hasWebAuthn: false })).toBe("no_webauthn"));
  it("WebAuthn ok but no Face ID / screen lock set up", () => {
    expect(bioReason(base)).toBe("no_lock_ios");
    expect(bioReason({ ...base, ua: UA.android })).toBe("no_lock_android");
  });
  it("every reason has an Arabic explanation", () => {
    for (const k of ["insecure", "in_app", "old_ios", "no_webauthn", "no_lock_ios", "no_lock_android"] as const) {
      expect(BIO_HELP[k].length).toBeGreaterThan(20);
    }
  });
});

describe("diagLine: one short line the employee can screenshot for the admin", () => {
  it("lists OS, browser, home screen, WebAuthn, lock", () => {
    const s = diagLine({ ua: UA.iphone17, secure: true, hasWebAuthn: true, platformAuth: false, standalone: false });
    expect(s).toBe("iOS 17.2 · Safari · من الشاشة الرئيسية: لا · WebAuthn: نعم · قفل/بصمة: لا");
  });
});

describe("geoPermission: the location permission without asking", () => {
  it("reads the state from the Permissions API", async () => {
    const perms = { query: vi.fn().mockResolvedValue({ state: "denied" }) };
    expect(await geoPermission(perms)).toBe("denied");
    expect(perms.query).toHaveBeenCalledWith({ name: "geolocation" });
  });
  it("no API or an error -> unknown (the tap will ask)", async () => {
    expect(await geoPermission(undefined)).toBe("unknown");
    expect(await geoPermission({ query: vi.fn().mockRejectedValue(new Error("x")) })).toBe("unknown");
  });
});

describe("geoHelp: what to do when the phone gives no location", () => {
  it("denied on Android names Chrome and Xiaomi/Redmi settings", () => {
    const t = geoHelp("denied", "android");
    expect(t).toContain("Chrome");
    expect(t).toContain("شاومي");
  });
  it("denied on iPhone names location services", () => expect(geoHelp("denied", "ios")).toContain("خدمات الموقع"));
  it("GPS off / timeout", () => {
    expect(geoHelp("unavailable", "android")).toContain("GPS");
    expect(geoHelp("timeout", "ios")).toContain("GPS");
  });
  it("a position was read -> nothing to say", () => expect(geoHelp("ok", "android")).toBeNull());
});

describe("setup gate after sign-in", () => {
  const req = { policy: "required" as const, has_device: false };
  it("phone must still be registered -> setup, even if seen before", () => {
    expect(setupGate(req, true)).toBe("setup");
  });
  it("first time on this phone -> setup", () => {
    expect(setupGate({ policy: "required", has_device: true }, false)).toBe("setup");
    expect(setupGate({ policy: "off", has_device: false }, false)).toBe("setup");
  });
  it("seen and registered -> home", () => expect(setupGate({ policy: "required", has_device: true }, true)).toBe("home"));
  it("seen, company does not need the fingerprint -> home", () => expect(setupGate({ policy: "off", has_device: false }, true)).toBe("home"));
});

describe("setup seen flag (per account, on this phone)", () => {
  it("is false until marked, and per user", () => {
    const m = new Map<string, string>();
    const store = { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
    expect(setupSeen("u1", store)).toBe(false);
    markSetupSeen("u1", store);
    expect(setupSeen("u1", store)).toBe(true);
    expect(setupSeen("u2", store)).toBe(false);
  });
  it("blocked storage never throws", () => {
    const bad = { getItem: () => { throw new Error("x"); }, setItem: () => { throw new Error("x"); } };
    expect(setupSeen("u1", bad)).toBe(false);
    expect(() => markSetupSeen("u1", bad)).not.toThrow();
  });
});

describe("ensureSubscription: on every open, keep this phone subscribed", () => {
  const keys = { endpoint: "https://fcm/x", keys: { p256dh: "p".repeat(87), auth: "a".repeat(22) } };
  const sub = { endpoint: keys.endpoint, toJSON: () => keys };
  it("permission not granted -> nothing (never asks by itself)", async () => {
    const pm = { getSubscription: vi.fn(), subscribe: vi.fn() };
    expect(await ensureSubscription({ permission: "default", pushManager: pm })).toBeNull();
    expect(pm.subscribe).not.toHaveBeenCalled();
  });
  it("granted and subscribed -> the same keys", async () => {
    const pm = { getSubscription: vi.fn().mockResolvedValue(sub), subscribe: vi.fn() };
    expect((await ensureSubscription({ permission: "granted", pushManager: pm }))?.endpoint).toBe("https://fcm/x");
    expect(pm.subscribe).not.toHaveBeenCalled();
  });
  it("granted but the subscription was lost -> subscribes again", async () => {
    const pm = { getSubscription: vi.fn().mockResolvedValue(null), subscribe: vi.fn().mockResolvedValue(sub) };
    expect((await ensureSubscription({ permission: "granted", pushManager: pm }))?.auth).toBe("a".repeat(22));
    expect(pm.subscribe).toHaveBeenCalledTimes(1);
  });
  it("the browser refuses -> null, no throw", async () => {
    const pm = { getSubscription: vi.fn().mockResolvedValue(null), subscribe: vi.fn().mockRejectedValue(new Error("no")) };
    expect(await ensureSubscription({ permission: "granted", pushManager: pm })).toBeNull();
  });
});
