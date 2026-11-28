import { describe, expect, it } from "vitest";
import { MAX_HISTORY_DAYS, checkRange, defaultRange, historySummary, queryWindow } from "./history";
import type { DayRow } from "./timecard";

describe("the period of the attendance log (two dates the employee picks)", () => {
  it("opens on the last 30 days, up to yesterday (today is on the Home screen)", () => {
    expect(defaultRange("2026-11-28")).toEqual({ from: "2026-10-29", to: "2026-11-27" });
  });
  it("a valid period: no message", () => {
    expect(checkRange("2026-11-01", "2026-11-27", "2026-11-28")).toBeNull();
    expect(checkRange("2026-11-27", "2026-11-27", "2026-11-28")).toBeNull();
  });
  it("missing dates, reversed dates, the future and too long a period each get one clear line", () => {
    expect(checkRange("", "2026-11-27", "2026-11-28")).toBe("اختر التاريخين.");
    expect(checkRange("2026-11-20", "2026-11-10", "2026-11-28")).toBe("تاريخ البداية بعد تاريخ النهاية.");
    expect(checkRange("2026-11-20", "2026-11-29", "2026-11-28")).toBe("لا يمكن اختيار يوم بعد اليوم.");
    expect(checkRange("2026-01-01", "2026-11-27", "2026-11-28")).toBe(`أقصى مدة ${MAX_HISTORY_DAYS} يومًا. اختر فترة أقصر.`);
  });
  it("the server is asked a little wider than the two days (time zones); the screen keeps only the chosen days", () => {
    expect(queryWindow("2026-11-01", "2026-11-27")).toEqual({ fromIso: "2026-10-31T00:00:00.000Z", toIso: "2026-11-29T00:00:00.000Z" });
  });
});

describe("the line above the list", () => {
  const day = (d: string, minutes: number, open = false): DayRow => ({ day: d, minutes, open, needsReview: false, byAdmin: false });
  it("days with a punch and the total time of complete days", () => {
    expect(historySummary([day("2026-11-27", 480), day("2026-11-26", 450), day("2026-11-25", 0, true)])).toBe("3 أيام حضور · المجموع 15 س 30 د");
  });
  it("nothing in the period", () => {
    expect(historySummary([])).toBe("لا توجد حركات في هذه الفترة.");
  });
});
