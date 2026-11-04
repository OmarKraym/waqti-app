import { formatTime } from "./attendance";

/** When the server allows the next punch (phase 8a). Times are the server's (ISO). */
export interface PunchWindow {
  allowed: boolean;
  opens_at: string | null;
  closes_at: string | null;
  reason: "no_limits" | "shift" | "overtime" | "day_off" | "too_early" | "too_late";
}

/** The line under a disabled punch button; null when punching is allowed. */
export function windowText(w: PunchWindow, timeZone: string, offLabel = "عطلة"): string | null {
  if (w.allowed) return null;
  if (w.reason === "day_off") return `اليوم ${offLabel}`;
  if (w.reason === "too_early" && w.opens_at && w.closes_at) {
    return `البصم متاح من ${formatTime(w.opens_at, timeZone)} إلى ${formatTime(w.closes_at, timeZone)}`;
  }
  return "انتهى وقت البصم لليوم";
}

/** Milliseconds until the window opens (measured on the server's clock), or null when nothing changes today. */
export function nextBoundaryMs(w: PunchWindow, serverNowMs: number): number | null {
  if (w.allowed || !w.opens_at) return null;
  return Math.max(0, Date.parse(w.opens_at) - serverNowMs);
}
