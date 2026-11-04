// Why the app signed the employee out (shown once on the sign-in screen).
export const SIGNOUT_REASON_KEY = "waqti-signout-reason";

export function takeSignoutReason(): "device_locked" | "login_again" | null {
  try {
    const v = sessionStorage.getItem(SIGNOUT_REASON_KEY);
    sessionStorage.removeItem(SIGNOUT_REASON_KEY);
    return v === "device_locked" || v === "login_again" ? v : null;
  } catch {
    return null;
  }
}
