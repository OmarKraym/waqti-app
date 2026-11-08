// After a late check-in the app asks the SERVER (employee_late_status) what to do and offers a late-arrival
// justification (a dialog) only when the server says `offer`. The app decides nothing about shifts, days off, the grace
// period, the company's counting rule or the monthly allowance: all of that is the server's call, in one place.
import { emptyDraft, formatMinutes, localDate, localHM, type Draft } from "./requests";
import type { LateStatus, PunchResult } from "./types";

export interface LateOffer {
  /** The request form, filled in: type "late arrival", today, arrival time = the time of the punch. */
  draft: Draft;
  /** The minutes that count against him (after the grace period, by the company's rule). */
  minutes: number;
  /** Justifications left this month; null = no monthly limit. */
  left: number | null;
}

/** The offer to show, or null. Only the reason `offer` makes one — any other reason (also a future one) is no offer. */
export function lateOfferFrom(status: LateStatus, punchIso: string, timeZone: string): LateOffer | null {
  if (!status.offer || status.reason !== "offer" || !status.permission) return null;
  const day = localDate(punchIso, timeZone);
  return {
    draft: {
      ...emptyDraft(day, status.permission), type: "permission", permission_type_id: status.permission.id,
      permission_mode: "late_arrival", date: day, to: localHM(punchIso, timeZone),
    },
    minutes: status.chargeable_min,
    left: status.remaining,
  };
}

/**
 * One line for the reasons where he is late but cannot request a justification and should know why; null otherwise
 * (on time, inside the grace period, day off, not the first check-in … or an offer, which has its own dialog).
 * The expected deduction is added only when no justification can change it (not for `already`: that one may excuse it).
 */
export function lateNote(status: LateStatus): string | null {
  if (status.chargeable_min <= 0) return null;
  const late = formatMinutes(status.late_min);
  const deduction = status.deduction_min && status.deduction_min > 0 ? ` الخصم المتوقع: ${formatMinutes(status.deduction_min)}.` : "";
  switch (status.reason) {
    case "no_balance":
      return `وصلت متأخرًا ${late}. استنفدت تبريرات التأخير لهذا الشهر.${deduction}`;
    case "too_long": {
      const max = status.permission?.max_minutes;
      const limit = max != null ? ` (${formatMinutes(max)})` : "";
      return `وصلت متأخرًا ${late}، وهذا أكثر من الحد المسموح لتبرير التأخير${limit}.${deduction}`;
    }
    case "already":
      return "وصلت متأخرًا، ولديك تبرير تأخير لهذا اليوم بالفعل.";
    default:
      return null;
  }
}

/**
 * Is it worth asking the server about this punch? Not for a retry the server already handled (`duplicate`), a check-out,
 * or a punch that was saved on the phone and sent later (`recorded_offline`: the moment has passed, and the app
 * would be answering about an old arrival).
 */
export function shouldAskLateStatus(result: PunchResult): boolean {
  return result.action === "check_in" && !result.duplicate && !result.recorded_offline;
}
