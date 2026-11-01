// Fingerprint (WebAuthn) in the employee app. The server issues the challenge and checks the signature
// (Edge Function "webauthn"); the phone only asks for the fingerprint / screen lock.
import { browserSupportsWebAuthn, platformAuthenticatorIsAvailable, startAuthentication, startRegistration } from "@simplewebauthn/browser";
import type { WaqtiApi } from "./api";
import { AppError } from "./errors";
import { clearDeviceHint, readDeviceHint, saveDeviceHint } from "./bioDevice";

export interface BiometricState {
  policy: "off" | "required";
  has_device: boolean;
  /** Fingerprint SIGN-IN switch of this employee (phase 10). Old saved states have none: it counts as on. */
  login_enabled?: boolean;
}

type WebauthnApi = Pick<WaqtiApi, "webauthn">;
type LoginApi = Pick<WaqtiApi, "webauthn" | "signInWithToken">;
/** Where the phone keeps the id of its own fingerprint credential (injected in tests). */
type HintSave = { save: (credentialId: string) => void };
type HintStore = { read: () => string | null; clear: () => void };
// The screens never look inside the WebAuthn option/response JSON, so it stays opaque here.
type Start = (args: { optionsJSON: never }) => Promise<unknown>;

/** True when this phone has a built-in authenticator (fingerprint / face / screen lock). */
export async function supportsPlatformAuthenticator(): Promise<boolean> {
  try {
    return browserSupportsWebAuthn() && (await platformAuthenticatorIsAvailable());
  } catch {
    return false;
  }
}

/** What must happen before a punch: nothing, register this phone, fingerprint, or punch flagged as "unsupported". */
export async function biometricStep(
  b: BiometricState,
  supported: () => Promise<boolean> = supportsPlatformAuthenticator,
): Promise<"none" | "register" | "fingerprint" | "unsupported"> {
  if (b.policy !== "required") return "none";
  const can = await supported();
  if (b.has_device) {
    if (!can) throw new AppError("biometric_required");
    return "fingerprint";
  }
  return can ? "register" : "unsupported";
}

function cancelled(e: unknown): boolean {
  const name = (e as { name?: string })?.name;
  return name === "NotAllowedError" || name === "AbortError" || name === "InvalidStateError";
}

/** Binds this phone to the account (one device per employee). */
export async function registerDevice(
  api: WebauthnApi,
  start: Start = startRegistration as unknown as Start,
  hint: HintSave = { save: saveDeviceHint },
): Promise<void> {
  const options = await api.webauthn("register-options");
  let response: unknown;
  try {
    response = await start({ optionsJSON: options as never });
  } catch (e) {
    throw new AppError(cancelled(e) ? "biometric_failed" : "unknown", String(e));
  }
  await api.webauthn("register-verify", { response });
  // Remember this phone's credential so the sign-in screen can offer the fingerprint after sign-out.
  const id = (response as { id?: unknown } | null)?.id;
  if (typeof id === "string") hint.save(id);
}

/** Fingerprint for ONE punch: the server then accepts a punch with this request id (once, within 2 minutes). */
export async function fingerprintTicket(
  api: WebauthnApi,
  requestId: string,
  start: Start = startAuthentication as unknown as Start,
  hint: HintSave = { save: saveDeviceHint },
): Promise<void> {
  const options = await api.webauthn("punch-options");
  // Phones registered before sign-in by fingerprint existed learn their credential id here.
  const known = (options as { allowCredentials?: { id?: unknown }[] } | null)?.allowCredentials?.[0]?.id;
  if (typeof known === "string") hint.save(known);
  let response: unknown;
  try {
    response = await start({ optionsJSON: options as never });
  } catch (e) {
    throw new AppError(cancelled(e) ? "biometric_failed" : "unknown", String(e));
  }
  await api.webauthn("punch-verify", { response, request_id: requestId });
}

/**
 * Sign in with this phone's fingerprint, after sign-out. Returns false when the person cancelled the prompt (not an
 * error). The server alone decides: it checks the signature against the registered key, that the employee and company
 * are active, and gives back a one-time token that opens a normal session. A "device not registered" answer makes the
 * phone forget its saved credential, so the button disappears and the password form is the way in.
 */
export async function loginWithFingerprint(
  api: LoginApi,
  start: Start = startAuthentication as unknown as Start,
  hint: HintStore = { read: readDeviceHint, clear: clearDeviceHint },
): Promise<boolean> {
  const credentialId = hint.read();
  if (!credentialId) throw new AppError("device_not_registered");
  const forgetIfGone = (e: unknown): never => {
    // not registered (admin removed the phone) or switched off by the employee: the button must go away
    if (e instanceof AppError && (e.code === "device_not_registered" || e.code === "login_disabled")) hint.clear();
    throw e;
  };
  const issued = (await api.webauthn("login-options", { credential_id: credentialId }).catch(forgetIfGone)) as
    | { options?: unknown; challenge_id?: unknown }
    | null;
  if (!issued || typeof issued.options !== "object" || issued.options === null || typeof issued.challenge_id !== "string") {
    throw new AppError("unknown");
  }
  let response: unknown;
  try {
    response = await start({ optionsJSON: issued.options as never });
  } catch (e) {
    if (cancelled(e)) return false;
    throw new AppError("unknown", String(e));
  }
  const done = (await api
    .webauthn("login-verify", { credential_id: credentialId, challenge_id: issued.challenge_id, response })
    .catch(forgetIfGone)) as { token_hash?: unknown } | null;
  if (!done || typeof done.token_hash !== "string") throw new AppError("unknown");
  await api.signInWithToken(done.token_hash);
  return true;
}

export type LoginToggle =
  | { kind: "off_by_company" }
  | { kind: "needs_device" }
  | { kind: "switch"; on: boolean; canTurnOn: boolean };

/** What the profile shows for "sign in with fingerprint". */
export function loginToggle(b: BiometricState | undefined, supported: boolean): LoginToggle {
  if (!b || b.policy !== "required") return { kind: "off_by_company" };
  if (!b.has_device) return { kind: "needs_device" };
  return { kind: "switch", on: b.login_enabled !== false, canTurnOn: supported };
}

/**
 * Turns fingerprint sign-in on or off for this employee. The server enforces it (a phone that still remembers its
 * fingerprint is refused while it is off). Off needs nothing; on needs a fresh fingerprint over a challenge from the
 * server. Returns the new state. A cancelled prompt throws biometric_failed and changes nothing.
 */
export async function setLoginEnabled(
  api: WebauthnApi,
  enabled: boolean,
  start: Start = startAuthentication as unknown as Start,
  hint: HintSave & { clear: () => void } = { save: saveDeviceHint, clear: clearDeviceHint },
): Promise<boolean> {
  if (!enabled) {
    await api.webauthn("set-login", { enabled: false });
    hint.clear(); // only after the server agreed: the sign-in button goes away on this phone at once
    return false;
  }
  const options = await api.webauthn("punch-options");
  const known = (options as { allowCredentials?: { id?: unknown }[] } | null)?.allowCredentials?.[0]?.id;
  let response: unknown;
  try {
    response = await start({ optionsJSON: options as never });
  } catch (e) {
    throw new AppError(cancelled(e) ? "biometric_failed" : "unknown", String(e));
  }
  await api.webauthn("set-login", { enabled: true, response });
  if (typeof known === "string") hint.save(known);
  return true;
}
