import { describe, expect, it, vi } from "vitest";
import { biometricStep, fingerprintTicket, registerDevice } from "./biometric";
import { AppError, ERROR_TEXT } from "./errors";

const notAllowed = () => Object.assign(new Error("The operation either timed out or was not allowed."), { name: "NotAllowedError" });

describe("what has to happen before a punch", () => {
  it("nothing when the company does not require it", async () => {
    expect(await biometricStep({ policy: "off", has_device: false }, async () => true)).toBe("none");
  });
  it("register first when this phone can do it", async () => {
    expect(await biometricStep({ policy: "required", has_device: false }, async () => true)).toBe("register");
  });
  it("punch flagged for review when this phone cannot", async () => {
    expect(await biometricStep({ policy: "required", has_device: false }, async () => false)).toBe("unsupported");
  });
  it("fingerprint when a device is registered", async () => {
    expect(await biometricStep({ policy: "required", has_device: true }, async () => true)).toBe("fingerprint");
  });
  it("a phone without fingerprint support cannot replace the registered one", async () => {
    await expect(biometricStep({ policy: "required", has_device: true }, async () => false)).rejects.toMatchObject({ code: "biometric_required" });
  });
});

describe("fingerprint before a punch", () => {
  it("asks the server, signs with the phone, sends it with the punch's request id", async () => {
    const calls: [string, unknown][] = [];
    const api = { webauthn: vi.fn(async (action: string, body?: unknown) => { calls.push([action, body]); return action === "punch-options" ? { challenge: "c1" } : { ok: true }; }) };
    const start = vi.fn(async () => ({ id: "cred" }));
    await fingerprintTicket(api, "req-1", start);
    expect(start).toHaveBeenCalledWith({ optionsJSON: { challenge: "c1" } });
    expect(calls).toEqual([["punch-options", undefined], ["punch-verify", { response: { id: "cred" }, request_id: "req-1" }]]);
  });
  it("a cancelled prompt stops here: nothing is sent", async () => {
    const api = { webauthn: vi.fn(async () => ({ challenge: "c1" })) };
    const err = await fingerprintTicket(api, "req-1", async () => { throw notAllowed(); }).catch((e) => e);
    expect(err).toBeInstanceOf(AppError);
    expect(err.code).toBe("biometric_failed");
    expect(ERROR_TEXT.biometric_failed).toBe("لم تتم البصمة");
    expect(api.webauthn).toHaveBeenCalledTimes(1); // only the options, never punch-verify
  });
});

describe("registering this phone", () => {
  it("creates a key with the server's options and sends it back", async () => {
    const api = { webauthn: vi.fn(async (action: string) => (action === "register-options" ? { challenge: "r1" } : { ok: true })) };
    const start = vi.fn(async () => ({ id: "new" }));
    await registerDevice(api, start);
    expect(api.webauthn).toHaveBeenLastCalledWith("register-verify", { response: { id: "new" } });
  });
  it("cancel -> biometric_failed", async () => {
    const api = { webauthn: vi.fn(async () => ({ challenge: "r1" })) };
    await expect(registerDevice(api, async () => { throw notAllowed(); })).rejects.toMatchObject({ code: "biometric_failed" });
  });
});
