import type { BiometricState } from "./biometric";

/** What comes after the new password: the fingerprint registration, an explanation (phone cannot), or the app. */
export type Gate = "device" | "unsupported" | "home";

/** The company decides (policy "required"); a phone that is already registered goes straight in. */
export function nextGate(b: BiometricState | undefined, supported: boolean): Gate {
  if (!b || b.policy !== "required" || b.has_device) return "home";
  return supported ? "device" : "unsupported";
}

/**
 * The server cannot be reached (e.g. the app is started with no connection): only the state saved on this phone is
 * known. A returning employee whose saved state says "not required" or "registered" gets in; anything else stays closed.
 */
export function gateWhenUnreachable(cached: BiometricState | undefined): "ready" | "error" {
  return cached && nextGate(cached, true) === "home" ? "ready" : "error";
}

/** An iPhone/iPad page opened in the browser, not from the home-screen icon. `standalone` is Safari's own flag. */
export function iosBrowserTab(ua: string, standalone: boolean | undefined): boolean {
  return /iPhone|iPad|iPod/i.test(ua) && standalone === false;
}
