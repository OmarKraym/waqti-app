import { describe, expect, it } from "vitest";
import { fromB64u, pushState, VAPID_PUBLIC_KEY } from "./push";
import { tabFromUrl } from "../screens/Main";

const env = { hasPush: true, isIos: false, standalone: false, permission: "default" as NotificationPermission, subscribed: false };

describe("push state on this device", () => {
  it("iPhone in Safari must install the app first", () => {
    expect(pushState({ ...env, isIos: true, standalone: false })).toBe("ios_install");
    expect(pushState({ ...env, isIos: true, standalone: true })).toBe("off");
  });
  it("blocked, unsupported, off, on", () => {
    expect(pushState({ ...env, permission: "denied" })).toBe("denied");
    expect(pushState({ ...env, hasPush: false })).toBe("unsupported");
    expect(pushState({ ...env, permission: "granted", subscribed: false })).toBe("off");
    expect(pushState({ ...env, permission: "granted", subscribed: true })).toBe("on");
  });
  it("the VAPID public key is an uncompressed P-256 point", () => {
    const k = fromB64u(VAPID_PUBLIC_KEY);
    expect(k.length).toBe(65);
    expect(k[0]).toBe(4);
  });
});

describe("opening the app from a notification", () => {
  it("reads the tab from the link", () => {
    expect(tabFromUrl("https://omarkraym.github.io/waqti-app/?tab=requests")).toBe("requests");
    expect(tabFromUrl("/waqti-app/?tab=notifications")).toBe("notifications");
    expect(tabFromUrl("https://omarkraym.github.io/waqti-app/")).toBeNull();
    expect(tabFromUrl("/waqti-app/?tab=evil")).toBeNull();
  });
});
