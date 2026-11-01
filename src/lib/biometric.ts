// Fingerprint (WebAuthn) in the employee app. The server issues the challenge and checks the signature
// (Edge Function "webauthn"); the phone only asks for the fingerprint / screen lock.
import { browserSupportsWebAuthn, platformAuthenticatorIsAvailable, startAuthentication, startRegistration } from "@simplewebauthn/browser";
import type { WaqtiApi } from "./api";
import { AppError } from "./errors";

export interface BiometricState {
  policy: "off" | "required";
  has_device: boolean;
}

type WebauthnApi = Pick<WaqtiApi, "webauthn">;
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
export async function registerDevice(api: WebauthnApi, start: Start = startRegistration as unknown as Start): Promise<void> {
  const options = await api.webauthn("register-options");
  let response: unknown;
  try {
    response = await start({ optionsJSON: options as never });
  } catch (e) {
    throw new AppError(cancelled(e) ? "biometric_failed" : "unknown", String(e));
  }
  await api.webauthn("register-verify", { response });
}

/** Fingerprint for ONE punch: the server then accepts a punch with this request id (once, within 2 minutes). */
export async function fingerprintTicket(api: WebauthnApi, requestId: string, start: Start = startAuthentication as unknown as Start): Promise<void> {
  const options = await api.webauthn("punch-options");
  let response: unknown;
  try {
    response = await start({ optionsJSON: options as never });
  } catch (e) {
    throw new AppError(cancelled(e) ? "biometric_failed" : "unknown", String(e));
  }
  await api.webauthn("punch-verify", { response, request_id: requestId });
}
