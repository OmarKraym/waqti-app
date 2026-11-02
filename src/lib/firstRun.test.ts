import { describe, expect, it } from "vitest";
import { gateWhenUnreachable, iosBrowserTab, nextGate } from "./firstRun";

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

describe("gateWhenUnreachable: the server cannot be reached, only the saved state is known", () => {
  it("saved state says policy off -> open the app (a returning employee can start it without a connection)", () => {
    expect(gateWhenUnreachable({ policy: "off", has_device: false })).toBe("ready");
  });
  it("saved state says this phone is registered -> open the app", () => {
    expect(gateWhenUnreachable({ policy: "required", has_device: true })).toBe("ready");
  });
  it("saved state says required and not registered -> stay closed", () => {
    expect(gateWhenUnreachable({ policy: "required", has_device: false })).toBe("error");
  });
  it("nothing saved (first time on this phone) -> stay closed", () => {
    expect(gateWhenUnreachable(undefined)).toBe("error");
  });
});
