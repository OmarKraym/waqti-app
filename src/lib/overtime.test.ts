import { describe, expect, it } from "vitest";
import { actualLine, emptyOvertimeDraft, limitsLine, overtimeHours, overtimeInput, shiftLine, sortOvertime } from "./overtime";
import type { OvertimeItem } from "./types";

const TZ = "Africa/Tripoli";
const item = (over: Partial<OvertimeItem>): OvertimeItem => ({
  id: "x", status: "assigned", phase: "upcoming", start_at: "2026-11-05T14:00:00Z", end_at: "2026-11-05T16:00:00Z", minutes: 120, task: null,
  employee: { id: "e", full_name: "سالم", employee_number: null, department: null }, assigned_by: { id: "m", full_name: "خالد" },
  employee_note: null, employee_noted_at: null, cancelled_at: null, cancelled_by_name: null, created_at: "", actual_minutes: null, ...over,
});

describe("overtime form", () => {
  it("not filled in yet: no error shown", () => {
    expect(overtimeInput(emptyOvertimeDraft("2026-11-05"), TZ)).toEqual({ ok: false, error: null });
    expect(overtimeInput({ ...emptyOvertimeDraft("2026-11-05", "e"), from: "18:00" }, TZ)).toEqual({ ok: false, error: null });
  });
  it("times become instants in the company time zone", () => {
    const r = overtimeInput({ employee_id: "e", date: "2026-11-05", from: "16:30", to: "18:30", task: " جرد " }, TZ);
    expect(r).toEqual({ ok: true, input: { employee_id: "e", start_at: "2026-11-05T14:30:00.000Z", end_at: "2026-11-05T16:30:00.000Z", task: "جرد" } });
  });
  it("end before start is refused", () => {
    expect(overtimeInput({ employee_id: "e", date: "2026-11-05", from: "20:00", to: "18:00", task: "" }, TZ)).toEqual({ ok: false, error: "invalid_dates" });
  });
});

describe("overtime wording", () => {
  it("hours", () => expect(overtimeHours(item({}), TZ)).toBe("4:00 م–6:00 م"));
  it("limits after this assignment", () => {
    const p = { minutes: 60, used_day: 60, used_month: 240, limit_day: 180, limit_month: null, shift_start: null, shift_end: null };
    expect(limitsLine(p)).toBe("اليوم: ساعتان من 3 ساعات · الشهر: 5 ساعات (بلا حد)");
  });
  it("shift of that day", () => {
    const p = { minutes: 60, used_day: 0, used_month: 0, limit_day: null, limit_month: null, shift_start: "2026-11-05T06:00:00Z", shift_end: "2026-11-05T14:00:00Z" };
    expect(shiftLine(p, TZ)).toBe("دوامه هذا اليوم \u20668:00 ص–4:00 م\u2069");
    expect(shiftLine({ ...p, shift_start: null, shift_end: null }, TZ)).toBe("هذا اليوم عطلته");
  });
  it("assigned vs actual", () => {
    expect(actualLine(item({ phase: "done", actual_minutes: 95 }))).toBe("عمل ساعة و35 د من ساعتين");
    expect(actualLine(item({ phase: "done", actual_minutes: 0 }))).toBe("لم يسجّل حضورًا في وقت التكليف");
    expect(actualLine(item({ phase: "now", actual_minutes: 30 }))).toBe("حتى الآن 30 د من ساعتين");
    expect(actualLine(item({ phase: "upcoming" }))).toBeNull();
  });
  it("live first (soonest), then past (latest)", () => {
    const list = sortOvertime([
      item({ id: "past1", phase: "done", start_at: "2026-10-01T10:00:00Z" }),
      item({ id: "soon2", phase: "upcoming", start_at: "2026-11-09T10:00:00Z" }),
      item({ id: "past2", phase: "done", start_at: "2026-10-20T10:00:00Z" }),
      item({ id: "soon1", phase: "upcoming", start_at: "2026-11-05T10:00:00Z" }),
    ]);
    expect(list.map((o) => o.id)).toEqual(["soon1", "soon2", "past2", "past1"]);
  });
});
