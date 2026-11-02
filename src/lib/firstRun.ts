import type { BiometricState } from "./biometric";

/** What comes after the new password: the fingerprint registration, an explanation (phone cannot), or the app. */
export type Gate = "device" | "unsupported" | "home";

/** The company decides (policy "required"); a phone that is already registered goes straight in. */
export function nextGate(b: BiometricState | undefined, supported: boolean): Gate {
  if (!b || b.policy !== "required" || b.has_device) return "home";
  return supported ? "device" : "unsupported";
}

/** An iPhone/iPad page opened in the browser, not from the home-screen icon. `standalone` is Safari's own flag. */
export function iosBrowserTab(ua: string, standalone: boolean | undefined): boolean {
  return /iPhone|iPad|iPod/i.test(ua) && standalone === false;
}
