import { describe, expect, it } from "vitest";
import { effectiveAction, isPunchLocked, lockedText, nextModeChangeMs } from "./punchMode";
import type { PunchMode } from "./types";

const TZ = "Africa/Tripoli"; // UTC+2
const FLIPS = "2026-11-07T10:00:00Z"; // 12:00 in Tripoli
const RESET = "2026-11-07T22:00:00Z"; // 00:00 the next day in Tripoli
const FLIPS_MS = Date.parse(FLIPS);

const locked: PunchMode = { auto: true, expected: "check_in", locked: true, flips_at: FLIPS, reset_at: RESET };
const open: PunchMode = { auto: true, expected: "check_out", locked: false, flips_at: FLIPS, reset_at: RESET };

describe("isPunchLocked: a check-in is open and the check-out has not opened yet", () => {
  it("is locked until the flip time and not from it", () => {
    expect(isPunchLocked(locked, FLIPS_MS - 1)).toBe(true);
    expect(isPunchLocked(locked, FLIPS_MS)).toBe(false);
  });
  it("is never locked when the mode is off, missing (older server) or not locked", () => {
    expect(isPunchLocked({ auto: false, locked: false }, FLIPS_MS - 1)).toBe(false);
    expect(isPunchLocked(undefined, FLIPS_MS - 1)).toBe(false);
    expect(isPunchLocked(open, FLIPS_MS - 1)).toBe(false);
  });
  it("is not locked without a flip time (nothing to wait for)", () => {
    expect(isPunchLocked({ auto: true, expected: "check_in", locked: true }, 0)).toBe(false);
  });
});

describe("effectiveAction: the label follows the clock between two loads of the state", () => {
  it("a locked state becomes check-out at the flip time, without waiting for the next load", () => {
    expect(effectiveAction("check_in", locked, FLIPS_MS - 1)).toBe("check_in");
    expect(effectiveAction("check_in", locked, FLIPS_MS)).toBe("check_out");
  });
  it("leaves the server's action alone otherwise", () => {
    expect(effectiveAction("check_out", open, FLIPS_MS + 5)).toBe("check_out");
    expect(effectiveAction("check_in", { auto: false, locked: false }, FLIPS_MS + 5)).toBe("check_in");
    expect(effectiveAction("check_in", undefined, FLIPS_MS + 5)).toBe("check_in");
  });
});

describe("lockedText: one line telling when the check-out opens (company clock)", () => {
  it("names the time", () => {
    expect(lockedText(locked, TZ)).toBe("تم تسجيل حضورك. يفتح الانصراف الساعة 12:00");
  });
  it("is null when there is nothing to say", () => {
    expect(lockedText(open, TZ)).toBeNull();
    expect(lockedText(undefined, TZ)).toBeNull();
  });
});

describe("nextModeChangeMs: when the screen must load the state again", () => {
  it("is the flip time while it is ahead, then the reset at 00:00", () => {
    expect(nextModeChangeMs(locked, FLIPS_MS - 1000)).toBe(FLIPS_MS);
    expect(nextModeChangeMs(open, FLIPS_MS + 1000)).toBe(Date.parse(RESET));
  });
  it("is null when the mode is off, missing or everything is in the past", () => {
    expect(nextModeChangeMs({ auto: false, locked: false }, 0)).toBeNull();
    expect(nextModeChangeMs(undefined, 0)).toBeNull();
    expect(nextModeChangeMs(open, Date.parse(RESET) + 1)).toBeNull();
  });
});
