import { describe, expect, it } from "vitest";
import { iosBrowserTab, nextGate } from "./firstRun";

describe("nextGate: what the employee sees after the new password", () => {
  const req = { policy: "required" as const, has_device: false };
  it("company does not ask for the fingerprint -> home", () => {
    expect(nextGate({ policy: "off", has_device: false }, true)).toBe("home");
  });
  it("required and this phone is already registered -> home", () => {
    expect(nextGate({ policy: "required", has_device: true }, true)).toBe("home");
  });
  it("required, no device, the phone can do it -> register first", () => {
    expect(nextGate(req, true)).toBe("device");
  });
  it("required, no device, the phone cannot -> explain, then continue", () => {
    expect(nextGate(req, false)).toBe("unsupported");
  });
  it("an old cached state without biometric info -> home", () => {
    expect(nextGate(undefined, true)).toBe("home");
  });
});

describe("iosBrowserTab: iPhone page opened in the browser, not from the home screen icon", () => {
  const iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15";
  const android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36";
  it("iPhone in a browser tab -> true", () => expect(iosBrowserTab(iphone, false)).toBe(true));
  it("iPhone installed (standalone) -> false", () => expect(iosBrowserTab(iphone, true)).toBe(false));
  it("Android -> false", () => expect(iosBrowserTab(android, false)).toBe(false));
  it("standalone unknown -> false", () => expect(iosBrowserTab(iphone, undefined)).toBe(false));
});
