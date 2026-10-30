import { describe, expect, it } from "vitest";
import { dayKey, earlierDays, formatDuration, todayRows } from "./timecard";
import type { AttendanceEvent } from "./types";

const TZ = "Africa/Tripoli"; // UTC+2
const at = (iso: string) => new Date(iso).toISOString();
const ev = (id: string, action: "check_in" | "check_out", iso: string, extra: Partial<AttendanceEvent> = {}): AttendanceEvent => ({
  id, action, server_time: at(iso), location_status: "inside", needs_review: false, ...extra,
});
const NOW = Date.parse("2026-10-30T11:00:00Z"); // 13:00 Tripoli, Friday 30 Oct

describe("day in the company time zone", () => {
  it("23:30 UTC is already the next day in Tripoli", () => {
    expect(dayKey("2026-10-29T23:30:00Z", TZ)).toBe("2026-10-30");
  });
});

describe("today's time card", () => {
  it("nothing today: two empty slots", () => {
    expect(todayRows([], null, NOW, TZ).map((r) => [r.action, r.kind])).toEqual([["check_in", "empty"], ["check_out", "empty"]]);
  });

  it("checked in: stamped check-in, then an empty check-out slot", () => {
    const rows = todayRows([ev("a", "check_in", "2026-10-30T06:02:00Z")], at("2026-10-30T06:02:00Z"), NOW, TZ);
    expect(rows.map((r) => [r.action, r.kind])).toEqual([["check_in", "stamped"], ["check_out", "empty"]]);
  });

  it("a punch waiting on the phone is pencil, not stamped", () => {
    const rows = todayRows([ev("queued:x", "check_in", "2026-10-30T06:02:00Z")], null, NOW, TZ);
    expect(rows[0].kind).toBe("pencil");
  });

  it("after the check-out no empty slot is added", () => {
    const rows = todayRows([ev("b", "check_out", "2026-10-30T14:00:00Z"), ev("a", "check_in", "2026-10-30T06:00:00Z")], null, NOW, TZ);
    expect(rows.map((r) => r.action)).toEqual(["check_in", "check_out"]);
  });

  it("night shift: yesterday's open check-in is shown on today's card", () => {
    const start = at("2026-10-29T20:00:00Z");
    const rows = todayRows([ev("a", "check_in", "2026-10-29T20:00:00Z")], start, NOW, TZ);
    expect(rows.map((r) => [r.action, r.kind])).toEqual([["check_in", "stamped"], ["check_out", "empty"]]);
  });

  it("yesterday's closed day does not appear on today's card", () => {
    const rows = todayRows([ev("a", "check_in", "2026-10-29T06:00:00Z"), ev("b", "check_out", "2026-10-29T14:00:00Z")], null, NOW, TZ);
    expect(rows.every((r) => r.kind === "empty")).toBe(true);
  });
});

describe("earlier days", () => {
  const events = [
    ev("t", "check_in", "2026-10-30T06:00:00Z"), // today: excluded
    ev("c", "check_out", "2026-10-29T14:03:00Z"),
    ev("b", "check_in", "2026-10-29T06:01:00Z"),
    ev("y", "check_in", "2026-10-28T05:58:00Z", { needs_review: true }),
  ];

  it("one row per day, newest first, today excluded", () => {
    expect(earlierDays(events, NOW, TZ).map((d) => d.day)).toEqual(["2026-10-29", "2026-10-28"]);
  });

  it("first in, last out and worked minutes", () => {
    const d = earlierDays(events, NOW, TZ)[0];
    expect(d.firstIn).toBe(at("2026-10-29T06:01:00Z"));
    expect(d.lastOut).toBe(at("2026-10-29T14:03:00Z"));
    expect(d.minutes).toBe(8 * 60 + 2);
    expect(d.open).toBe(false);
  });

  it("a day without check-out is marked open and its review flag is kept", () => {
    const d = earlierDays(events, NOW, TZ)[1];
    expect(d.open).toBe(true);
    expect(d.minutes).toBe(0);
    expect(d.needsReview).toBe(true);
  });

  it("duration text", () => {
    expect(formatDuration(482)).toBe("8 س 02 د");
    expect(formatDuration(45)).toBe("45 د");
  });
});
