import { describe, expect, it } from "vitest";
import { statusHeadline } from "./statusHeadline";
import { todayRows } from "./timecard";
import type { AttendanceEvent, AttendanceState } from "./types";

const TZ = "Africa/Tripoli";
const NOW = Date.parse("2026-11-09T14:00:00Z"); // 16:00 in Tripoli, the day the events below belong to

const base: AttendanceState = {
  employee: { full_name: "موظف", employee_number: "1" },
  company: { name: "شركة", timezone: TZ },
  next_action: "check_in",
  open_session: null,
  location_policy: "geofence",
  outside_action: "flag",
  max_accuracy_m: 100,
  recent_events: [],
  server_time: "2026-11-09T14:00:00Z",
  time_token: "tok",
  punch_window: { allowed: true, opens_at: null, closes_at: null, reason: "no_limits" },
  biometric: { policy: "off", has_device: false },
};

const ev = (id: string, action: "check_in" | "check_out", iso: string, needs_review = false): AttendanceEvent => ({
  id, action, server_time: iso, location_status: "inside", needs_review,
});
const head = (data: AttendanceState, events: AttendanceEvent[]) =>
  statusHeadline(data, todayRows(events, data.open_session?.started_at ?? null, NOW, TZ), NOW, TZ);

describe("status headline", () => {
  it("an open session says since when he is present", () => {
    const i = ev("1", "check_in", "2026-11-09T07:06:00Z");
    expect(head({ ...base, open_session: { started_at: i.server_time }, recent_events: [i] }, [i])).toBe("أنت حاضر منذ 9:06 ص");
  });

  it("#69: a check-in with no check-out and no open session (the shift window ended) is NOT 'not checked in'", () => {
    const i = ev("1", "check_in", "2026-11-09T07:06:00Z", true);
    const h = head({ ...base, recent_events: [i] }, [i]);
    expect(h).toBe("حضرت الساعة 9:06 ص ولم تسجّل الانصراف");
    expect(h).not.toContain("لم تسجّل حضورك");
  });

  it("a check-in and a check-out: the check-out time", () => {
    const i = ev("1", "check_in", "2026-11-09T07:06:00Z");
    const o = ev("2", "check_out", "2026-11-09T13:00:00Z");
    expect(head({ ...base, recent_events: [o, i] }, [o, i])).toBe("سجّلت انصرافك الساعة 3:00 م");
  });

  it("a second check-in after a check-out that was never closed: the latest movement decides", () => {
    const i = ev("1", "check_in", "2026-11-09T07:06:00Z");
    const o = ev("2", "check_out", "2026-11-09T10:00:00Z");
    const i2 = ev("3", "check_in", "2026-11-09T11:00:00Z");
    expect(head({ ...base, recent_events: [i2, o, i] }, [i2, o, i])).toBe("حضرت الساعة 1:00 م ولم تسجّل الانصراف");
  });

  it("nothing today and no leave", () => {
    expect(head(base, [])).toBe("لم تسجّل حضورك اليوم");
  });

  it("#70: on an approved leave today, nothing punched: it says so instead of 'not checked in'", () => {
    const data: AttendanceState = { ...base, leave_today: { request_id: "r1", leave_type: "annual", end_date: "2026-11-11" } };
    expect(head(data, [])).toBe("أنت في إجازة معتمدة اليوم");
  });

  it("#70: leave_today = null behaves as no leave", () => {
    expect(head({ ...base, leave_today: null }, [])).toBe("لم تسجّل حضورك اليوم");
  });

  it("#70: what he punched wins over the leave line (a restored day he still worked)", () => {
    const i = ev("1", "check_in", "2026-11-09T07:06:00Z");
    const data: AttendanceState = { ...base, recent_events: [i], leave_today: { request_id: "r1", leave_type: "annual", end_date: "2026-11-09" } };
    expect(head(data, [i])).toBe("حضرت الساعة 9:06 ص ولم تسجّل الانصراف");
  });

  it("a punch still waiting on the phone never reads as done", () => {
    const i = ev("queued:r1", "check_in", "2026-11-09T07:06:00Z");
    expect(head({ ...base, recent_events: [i] }, [i])).toBe("حضورك لم يُرسل بعد");
  });
});
