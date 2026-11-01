import { describe, expect, it } from "vitest";
import { nextBoundaryMs, windowText, type PunchWindow } from "./punchWindow";

const TZ = "Africa/Tripoli";
const at = (hhmm: string) => `2026-11-03T${hhmm}:00+02:00`;

describe("the line under the punch button", () => {
  it("says nothing when punching is allowed", () => {
    expect(windowText({ allowed: true, opens_at: null, closes_at: null, reason: "shift" }, TZ)).toBeNull();
    expect(windowText({ allowed: true, opens_at: null, closes_at: null, reason: "no_limits" }, TZ)).toBeNull();
  });
  it("gives the next window when it is too early", () => {
    const w: PunchWindow = { allowed: false, opens_at: at("07:00"), closes_at: at("10:00"), reason: "too_early" };
    expect(windowText(w, TZ)).toBe("البصم متاح من 07:00 إلى 10:00");
  });
  it("says it is a day off", () => {
    expect(windowText({ allowed: false, opens_at: null, closes_at: null, reason: "day_off" }, TZ)).toBe("اليوم عطلة");
  });
  it("says punching is over for today", () => {
    expect(windowText({ allowed: false, opens_at: null, closes_at: null, reason: "too_late" }, TZ)).toBe("انتهى وقت البصم لليوم");
  });
});

describe("when to ask the server again", () => {
  const now = Date.parse(at("06:30"));
  it("when the window opens", () => {
    const w: PunchWindow = { allowed: false, opens_at: at("07:00"), closes_at: at("10:00"), reason: "too_early" };
    expect(nextBoundaryMs(w, now)).toBe(30 * 60 * 1000);
  });
  it("never: allowed without limits, or nothing left today", () => {
    expect(nextBoundaryMs({ allowed: true, opens_at: null, closes_at: null, reason: "no_limits" }, now)).toBeNull();
    expect(nextBoundaryMs({ allowed: false, opens_at: null, closes_at: null, reason: "too_late" }, now)).toBeNull();
  });
  it("a boundary already passed (phone clock behind) means: ask now", () => {
    const w: PunchWindow = { allowed: false, opens_at: at("06:00"), closes_at: at("09:00"), reason: "too_early" };
    expect(nextBoundaryMs(w, now)).toBe(0);
  });
});
