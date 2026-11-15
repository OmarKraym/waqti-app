// Phase 25: the automatic punch mode, as the screen needs it. The server decides everything (see AttendanceState.punch_mode);
// these helpers only read its answer against the clock, so the button follows the time between two loads of the state.
import { localHM } from "./requests";
import type { AttendanceAction, PunchMode } from "./types";

/** Checked in, and the check-out has not opened yet: the button waits. */
export function isPunchLocked(mode: PunchMode | undefined, nowMs: number): boolean {
  if (!mode?.auto || !mode.locked || !mode.flips_at) return false;
  return nowMs < Date.parse(mode.flips_at);
}

/** The server's action, moved on to check-out when a locked state has reached its flip time (before the next load). */
export function effectiveAction(action: AttendanceAction, mode: PunchMode | undefined, nowMs: number): AttendanceAction {
  if (mode?.auto && mode.locked && mode.flips_at && nowMs >= Date.parse(mode.flips_at)) return "check_out";
  return action;
}

/** The line under the disabled button, or null. */
export function lockedText(mode: PunchMode | undefined, timeZone: string): string | null {
  if (!mode?.auto || !mode.locked || !mode.flips_at) return null;
  return `تم تسجيل حضورك. يفتح الانصراف الساعة ${localHM(mode.flips_at, timeZone)}`;
}

/** The next moment (ms) the state must be loaded again: the flip time while it is ahead, then the reset at 00:00. */
export function nextModeChangeMs(mode: PunchMode | undefined, nowMs: number): number | null {
  if (!mode?.auto) return null;
  const ahead = [mode.flips_at, mode.reset_at]
    .map((iso) => (iso ? Date.parse(iso) : NaN))
    .filter((ms) => Number.isFinite(ms) && ms > nowMs);
  return ahead.length ? Math.min(...ahead) : null;
}
