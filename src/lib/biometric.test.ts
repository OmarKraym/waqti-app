import { describe, expect, it, vi } from "vitest";
import { biometricStep, fingerprintTicket, loginToggle, loginWithFingerprint, registerDevice, setLoginEnabled } from "./biometric";
import { clearDeviceHint, readDeviceHint, saveDeviceHint } from "./bioDevice";
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

function memoryStorage() {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) };
}

describe("fingerprint sign-in (after sign-out)", () => {
  const hint = (id: string | null) => {
    const store = memoryStorage();
    if (id) saveDeviceHint(id, store);
    return { read: () => readDeviceHint(store), clear: () => clearDeviceHint(store), store };
  };
  const apiFor = (answers: Record<string, unknown | Error>) => {
    const calls: [string, unknown][] = [];
    const api = {
      webauthn: vi.fn(async (action: string, body?: unknown) => {
        calls.push([action, body]);
        const a = answers[action];
        if (a instanceof Error) throw a;
        return a;
      }),
      signInWithToken: vi.fn(async () => undefined),
    };
    return { api, calls };
  };
  const optionsAnswer = { options: { challenge: "c9", allowCredentials: [{ id: "cred-1" }] }, challenge_id: "ch-1" };

  it("asks for a challenge for THIS phone's credential, signs, verifies, then opens the session with the one-time token", async () => {
    const h = hint("cred-1");
    const { api, calls } = apiFor({ "login-options": optionsAnswer, "login-verify": { token_hash: "tok-1" } });
    const start = vi.fn(async () => ({ id: "cred-1", response: "signed" }));
    expect(await loginWithFingerprint(api, start, h)).toBe(true);
    expect(start).toHaveBeenCalledWith({ optionsJSON: optionsAnswer.options });
    expect(calls).toEqual([
      ["login-options", { credential_id: "cred-1" }],
      ["login-verify", { credential_id: "cred-1", challenge_id: "ch-1", response: { id: "cred-1", response: "signed" } }],
    ]);
    expect(api.signInWithToken).toHaveBeenCalledWith("tok-1");
  });
  it("no saved phone: nothing is sent", async () => {
    const { api } = apiFor({});
    const err = await loginWithFingerprint(api, async () => ({}), hint(null)).catch((e) => e);
    expect(err).toMatchObject({ code: "device_not_registered" });
    expect(api.webauthn).not.toHaveBeenCalled();
  });
  it("a cancelled prompt is not an error and sends nothing more", async () => {
    const h = hint("cred-1");
    const { api } = apiFor({ "login-options": optionsAnswer });
    const out = await loginWithFingerprint(api, async () => { throw notAllowed(); }, h);
    expect(out).toBe(false);
    expect(api.webauthn).toHaveBeenCalledTimes(1);
    expect(api.signInWithToken).not.toHaveBeenCalled();
    expect(h.read()).toBe("cred-1"); // cancelling does not forget the phone
  });
  it("the server says the phone is not registered (admin removed it): the saved phone is forgotten", async () => {
    const h = hint("cred-1");
    const { api } = apiFor({ "login-options": new AppError("device_not_registered") });
    const err = await loginWithFingerprint(api, async () => ({}), h).catch((e) => e);
    expect(err).toMatchObject({ code: "device_not_registered" });
    expect(h.read()).toBeNull();
  });
  it("a wrong fingerprint is an error but the phone stays remembered", async () => {
    const h = hint("cred-1");
    const { api } = apiFor({ "login-options": optionsAnswer, "login-verify": new AppError("biometric_failed") });
    const err = await loginWithFingerprint(api, async () => ({ id: "cred-1" }), h).catch((e) => e);
    expect(err).toMatchObject({ code: "biometric_failed" });
    expect(h.read()).toBe("cred-1");
    expect(api.signInWithToken).not.toHaveBeenCalled();
  });
  it("lock, password-only, company-off and inactive-account errors reach the screen with their own code and keep the phone", async () => {
    for (const code of ["too_many_attempts", "password_required", "biometric_off", "employee_inactive"] as const) {
      const h = hint("cred-1");
      const { api } = apiFor({ "login-options": new AppError(code) });
      const err = await loginWithFingerprint(api, async () => ({}), h).catch((e) => e);
      expect(err).toMatchObject({ code });
      expect(h.read()).toBe("cred-1");
      expect(ERROR_TEXT[code].length).toBeGreaterThan(10);
    }
  });
  it("an answer without the expected fields is refused, never half-used", async () => {
    const h = hint("cred-1");
    expect(await loginWithFingerprint(apiFor({ "login-options": { nope: 1 } }).api, async () => ({}), h).catch((e) => e)).toMatchObject({ code: "unknown" });
    const a = apiFor({ "login-options": optionsAnswer, "login-verify": { token_hash: 5 } });
    expect(await loginWithFingerprint(a.api, async () => ({ id: "cred-1" }), h).catch((e) => e)).toMatchObject({ code: "unknown" });
    expect(a.api.signInWithToken).not.toHaveBeenCalled();
  });
});

describe("the phone remembers its fingerprint for next time", () => {
  it("after registering, the credential id is saved", async () => {
    const store = memoryStorage();
    const api = { webauthn: vi.fn(async (a: string) => (a === "register-options" ? { challenge: "c" } : { ok: true })) };
    await registerDevice(api, async () => ({ id: "new-cred" }), { save: (id) => saveDeviceHint(id, store) });
    expect(readDeviceHint(store)).toBe("new-cred");
  });
  it("a punch's options also refresh it (phones registered before this feature)", async () => {
    const store = memoryStorage();
    const api = { webauthn: vi.fn(async (a: string) => (a === "punch-options" ? { challenge: "c", allowCredentials: [{ id: "old-cred" }] } : { ok: true })) };
    await fingerprintTicket(api, "req-1", async () => ({ id: "old-cred" }), { save: (id) => saveDeviceHint(id, store) });
    expect(readDeviceHint(store)).toBe("old-cred");
  });
  it("a failed registration saves nothing", async () => {
    const store = memoryStorage();
    const api = { webauthn: vi.fn(async (a: string) => { if (a === "register-verify") throw new AppError("biometric_failed"); return { challenge: "c" }; }) };
    await registerDevice(api, async () => ({ id: "new-cred" }), { save: (id) => saveDeviceHint(id, store) }).catch(() => undefined);
    expect(readDeviceHint(store)).toBeNull();
  });
});

describe("what the profile shows for fingerprint sign-in", () => {
  it("company rule off: nothing to switch", () => {
    expect(loginToggle({ policy: "off", has_device: false }, true)).toEqual({ kind: "off_by_company" });
    expect(loginToggle(undefined, true)).toEqual({ kind: "off_by_company" });
  });
  it("no phone registered yet: tell the employee to register by punching first", () => {
    expect(loginToggle({ policy: "required", has_device: false }, true)).toEqual({ kind: "needs_device" });
  });
  it("a registered phone: a switch, on unless the server says off (old saved states have no flag = on)", () => {
    expect(loginToggle({ policy: "required", has_device: true, login_enabled: true }, true)).toEqual({ kind: "switch", on: true, canTurnOn: true });
    expect(loginToggle({ policy: "required", has_device: true, login_enabled: false }, true)).toEqual({ kind: "switch", on: false, canTurnOn: true });
    expect(loginToggle({ policy: "required", has_device: true }, true)).toEqual({ kind: "switch", on: true, canTurnOn: true });
  });
  it("a phone without fingerprint support can still turn it off, but not on", () => {
    expect(loginToggle({ policy: "required", has_device: true, login_enabled: false }, false)).toEqual({ kind: "switch", on: false, canTurnOn: false });
  });
});

describe("turning fingerprint sign-in on or off", () => {
  const apiFor = (answers: Record<string, unknown | Error> = {}) => {
    const calls: [string, unknown][] = [];
    const api = {
      webauthn: vi.fn(async (action: string, body?: unknown) => {
        calls.push([action, body]);
        const a = answers[action];
        if (a instanceof Error) throw a;
        return a ?? (action === "punch-options" ? { challenge: "c1", allowCredentials: [{ id: "cred-1" }] } : action === "set-login" ? { login_enabled: (body as { enabled: boolean }).enabled } : { ok: true });
      }),
    };
    return { api, calls };
  };
  const hint = () => { const saved: string[] = []; let cleared = 0; return { save: (id: string) => void saved.push(id), clear: () => void cleared++, saved, get cleared() { return cleared; } }; };

  it("off: asks the server, no fingerprint prompt, and this phone forgets its saved fingerprint at once", async () => {
    const { api, calls } = apiFor(); const h = hint(); const start = vi.fn();
    expect(await setLoginEnabled(api, false, start as never, h)).toBe(false);
    expect(calls).toEqual([["set-login", { enabled: false }]]);
    expect(start).not.toHaveBeenCalled();
    expect(h.cleared).toBe(1);
  });
  it("off: if the server refuses, the phone keeps its saved fingerprint", async () => {
    const { api } = apiFor({ "set-login": new AppError("network") }); const h = hint();
    await expect(setLoginEnabled(api, false, vi.fn() as never, h)).rejects.toMatchObject({ code: "network" });
    expect(h.cleared).toBe(0);
  });
  it("on: a fresh fingerprint over the server's challenge, then the answer goes to the server; the phone remembers its credential", async () => {
    const { api, calls } = apiFor(); const h = hint();
    const start = vi.fn(async () => ({ id: "cred-1", response: "signed" }));
    expect(await setLoginEnabled(api, true, start as never, h)).toBe(true);
    expect(start).toHaveBeenCalledWith({ optionsJSON: { challenge: "c1", allowCredentials: [{ id: "cred-1" }] } });
    expect(calls).toEqual([["punch-options", undefined], ["set-login", { enabled: true, response: { id: "cred-1", response: "signed" } }]]);
    expect(h.saved).toEqual(["cred-1"]);
  });
  it("on: a cancelled prompt changes nothing", async () => {
    const { api, calls } = apiFor(); const h = hint();
    await expect(setLoginEnabled(api, true, (async () => { throw notAllowed(); }) as never, h)).rejects.toMatchObject({ code: "biometric_failed" });
    expect(calls.map((c) => c[0])).toEqual(["punch-options"]);
    expect(h.saved).toEqual([]);
  });
  it("on: the server's refusal is passed on and nothing is remembered", async () => {
    const { api } = apiFor({ "set-login": new AppError("biometric_failed") }); const h = hint();
    await expect(setLoginEnabled(api, true, (async () => ({ id: "cred-1" })) as never, h)).rejects.toMatchObject({ code: "biometric_failed" });
    expect(h.saved).toEqual([]);
  });
});

describe("sign-in screen when the employee turned it off", () => {
  it("login_disabled from the server: the saved phone is forgotten (the button goes away) and the error reaches the screen", async () => {
    const store = memoryStorage(); saveDeviceHint("cred-1", store);
    const hint = { read: () => readDeviceHint(store), clear: () => clearDeviceHint(store) };
    const api = { webauthn: vi.fn(async () => { throw new AppError("login_disabled"); }), signInWithToken: vi.fn() };
    const err = await loginWithFingerprint(api, async () => ({}), hint).catch((e) => e);
    expect(err).toMatchObject({ code: "login_disabled" });
    expect(readDeviceHint(store)).toBeNull();
    expect(ERROR_TEXT.login_disabled.length).toBeGreaterThan(10);
  });
});
