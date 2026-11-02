import { describe, expect, it } from "vitest";
import { clockParts, format12, from12, to12, wheelIndex, zonedHMS } from "./time12";

describe("12-hour clock with ص / م", () => {
  it("midnight is 12 ص and noon is 12 م", () => {
    expect(to12(0, 5)).toEqual({ h: 12, mm: "05", period: "ص" });
    expect(to12(12, 0)).toEqual({ h: 12, mm: "00", period: "م" });
  });
  it("morning and afternoon", () => {
    expect(format12(8, 5)).toBe("8:05 ص");
    expect(format12(11, 59)).toBe("11:59 ص");
    expect(format12(13, 0)).toBe("1:00 م");
    expect(format12(23, 30)).toBe("11:30 م");
  });
  it("back to a 24-hour value (what the server and the forms use)", () => {
    expect(from12(12, "00", "ص")).toBe("00:00");
    expect(from12(12, "30", "م")).toBe("12:30");
    expect(from12(8, "05", "ص")).toBe("08:05");
    expect(from12(11, "45", "م")).toBe("23:45");
  });
  it("every minute of the day survives the round trip", () => {
    for (let h = 0; h < 24; h++) {
      for (const m of [0, 1, 29, 30, 59]) {
        const t = to12(h, m);
        expect(from12(t.h, t.mm, t.period)).toBe(`${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`);
      }
    }
  });
  it("reads the wall clock of the company time zone (Tripoli = UTC+2)", () => {
    expect(zonedHMS("2026-10-30T18:05:09Z", "Africa/Tripoli")).toEqual({ h: 20, m: 5, s: 9 });
    expect(zonedHMS("2026-10-30T22:30:00Z", "Africa/Tripoli")).toEqual({ h: 0, m: 30, s: 0 });
  });
  it("live clock parts for the today screen", () => {
    expect(clockParts("2026-10-30T18:05:09Z", "Africa/Tripoli")).toEqual({ hm: "8:05", ss: "09", period: "م" });
    expect(clockParts("2026-10-30T22:30:00Z", "Africa/Tripoli")).toEqual({ hm: "12:30", ss: "00", period: "ص" });
  });

  it("a wheel rests on the nearest row and never leaves the list", () => {
    expect(wheelIndex(0, 44, 12)).toBe(0);
    expect(wheelIndex(60, 44, 12)).toBe(1);
    expect(wheelIndex(66, 44, 12)).toBe(2);
    expect(wheelIndex(-30, 44, 12)).toBe(0);
    expect(wheelIndex(9999, 44, 12)).toBe(11);
  });
});
