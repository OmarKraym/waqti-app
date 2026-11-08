import { formatTime } from "./attendance";
import { dayKey, type CardRow } from "./timecard";
import type { AttendanceState } from "./types";

/** The one line under the clock on the Home screen: what the server and today's card say about him right now. */
export function statusHeadline(data: AttendanceState, rows: CardRow[], nowMs: number, tz: string): string {
  // Nothing counts until the server stamps it: a pencil entry never reads as done.
  const last = [...rows].reverse().find((r) => r.kind !== "empty");
  if (last?.kind === "pencil") {
    return last.action === "check_in" ? "حضورك لم يُرسل بعد" : "انصرافك لم يُرسل بعد";
  }
  if (data.open_session) {
    const start = data.open_session.started_at;
    const sameDay = dayKey(start, tz) === dayKey(nowMs, tz);
    return `أنت حاضر منذ ${sameDay ? "" : "أمس "}${formatTime(start, tz)}`;
  }
  // What he did today decides, by the latest stamped movement. A check-in with no check-out and no open session is a session the server
  // closed (the shift window ended): he did check in, so never say he did not.
  if (last?.time) {
    return last.action === "check_out"
      ? `سجّلت انصرافك الساعة ${formatTime(last.time, tz)}`
      : `حضرت الساعة ${formatTime(last.time, tz)} ولم تسجّل الانصراف`;
  }
  // Nothing punched today: an approved leave covers today (phase 22), so nothing is asked of him.
  if (data.leave_today) return "أنت في إجازة معتمدة اليوم";
  return "لم تسجّل حضورك اليوم";
}
