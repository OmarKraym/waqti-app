import { describe, expect, it } from "vitest";
import { formatClock, reduce, successNotice, type ScreenState } from "./attendance";
import { AppError } from "./errors";
import { readLocation } from "./location";
import type { AttendanceState, PunchResult } from "./types";

const base: AttendanceState = {
  employee: { full_name: "موظف", employee_number: "1" },
  company: { name: "شركة", timezone: "Africa/Tripoli" },
  next_action: "check_in",
  open_session: null,
  location_policy: "geofence",
  outside_action: "flag",
  max_accuracy_m: 100,
  recent_events: [],
  server_time: "2026-10-29T06:00:00Z",
  time_token: "tok",
  punch_window: { allowed: true, opens_at: null, closes_at: null, reason: "no_limits" },
  biometric: { policy: "off", has_device: false },
};

const ready: ScreenState = { phase: "ready", data: base, notice: null, refreshing: false };

const ok: PunchResult = {
  event_id: "e1",
  action: "check_in",
  server_time: "2026-10-29T07:05:00Z", // 09:05 in Tripoli
  location_status: "inside",
  needs_review: false,
  duplicate: false,
};

function toSubmitting(): ScreenState {
  let s = reduce(ready, { type: "TAP", request_id: "r1", action: "check_in" });
  s = reduce(s, { type: "LOCATED", reading: { kind: "ok", lat: 1, lng: 2, accuracy_m: 10 } });
  return s;
}

describe("attendance state machine", () => {
  it("the action comes from the server state", () => {
    const s = reduce(ready, { type: "TAP", request_id: "r1", action: "check_in" });
    expect(s.phase).toBe("locating");
    if (s.phase === "locating") expect(s.pending.action).toBe("check_in");
  });

  it("ignores a second tap while a punch is in progress", () => {
    const s1 = reduce(ready, { type: "TAP", request_id: "r1", action: "check_in" });
    const s2 = reduce(s1, { type: "TAP", request_id: "r2", action: "check_in" });
    expect(s2).toBe(s1);
  });

  it("does not show success before the server answers", () => {
    const s = toSubmitting();
    expect(s.phase).toBe("submitting");
    expect("notice" in s).toBe(false);
  });

  it("shows success with the SERVER time in the company time zone and flips the button", () => {
    const s = reduce(toSubmitting(), { type: "PUNCH_OK", result: ok });
    expect(s.phase).toBe("ready");
    if (s.phase !== "ready") return;
    expect(s.data.next_action).toBe("check_out");
    expect(s.data.open_session?.started_at).toBe(ok.server_time);
    expect(s.notice?.kind).toBe("success");
    expect(s.notice?.text).toContain("09:05");
  });

  it("network error = unconfirmed (not failed, not saved), and retry keeps the same request id", () => {
    const s1 = reduce(toSubmitting(), { type: "PUNCH_FAIL", error: new AppError("network") });
    expect(s1.phase).toBe("unconfirmed");
    const s2 = reduce(s1, { type: "RETRY" });
    expect(s2.phase).toBe("submitting");
    if (s2.phase === "submitting") expect(s2.pending.request_id).toBe("r1");
  });

  it("a clear server error goes back to ready with an error message and the same button", () => {
    const s = reduce(toSubmitting(), { type: "PUNCH_FAIL", error: new AppError("outside_geofence") });
    expect(s.phase).toBe("ready");
    if (s.phase !== "ready") return;
    expect(s.notice?.kind).toBe("error");
    expect(s.data.next_action).toBe("check_in");
  });

  it("fresh server state after an unconfirmed punch replaces the pending tap", () => {
    const s1 = reduce(toSubmitting(), { type: "PUNCH_FAIL", error: new AppError("network") });
    const s2 = reduce(s1, { type: "LOAD_OK", data: { ...base, next_action: "check_out" } });
    expect(s2.phase).toBe("ready");
    if (s2.phase === "ready") expect(s2.data.next_action).toBe("check_out");
  });

  it("a refresh never interrupts a punch in progress", () => {
    const s = toSubmitting();
    expect(reduce(s, { type: "LOAD_START" })).toBe(s);
    expect(reduce(s, { type: "LOAD_OK", data: base })).toBe(s);
  });

  it("flagged punches say they were saved AND need review", () => {
    const n = successNotice({ ...ok, location_status: "outside", needs_review: true }, "Africa/Tripoli");
    expect(n.kind).toBe("warning");
    expect(n.text).toContain("تم تسجيل الحضور");
    expect(n.text).toContain("خارج نطاق");
  });
});

describe("location reading", () => {
  const fakeGeo = (behavior: "ok" | 1 | 2 | 3): Geolocation =>
    ({
      getCurrentPosition: (success: PositionCallback, error?: PositionErrorCallback | null) => {
        if (behavior === "ok")
          success({ coords: { latitude: 32.75, longitude: 12.72, accuracy: 18.4 } } as GeolocationPosition);
        else error?.({ code: behavior, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 } as GeolocationPositionError);
      },
    }) as unknown as Geolocation;

  it("'none' policy never touches the location API", async () => {
    let called = false;
    const geo = { getCurrentPosition: () => (called = true) } as unknown as Geolocation;
    expect(await readLocation("none", geo)).toEqual({ kind: "not_requested" });
    expect(called).toBe(false);
  });

  it("maps every failure separately (denied / unavailable / timeout / unsupported)", async () => {
    expect((await readLocation("geofence", fakeGeo(1))).kind).toBe("denied");
    expect((await readLocation("geofence", fakeGeo(2))).kind).toBe("unavailable");
    expect((await readLocation("record", fakeGeo(3))).kind).toBe("timeout");
    expect((await readLocation("record", undefined)).kind).toBe("unsupported");
  });

  it("returns rounded accuracy with the coordinates", async () => {
    expect(await readLocation("geofence", fakeGeo("ok"))).toEqual({ kind: "ok", lat: 32.75, lng: 12.72, accuracy_m: 18 });
  });
});

describe("live clock", () => {
  it("shows seconds, 24-hour, Western digits, company time zone", () => {
    expect(formatClock("2026-10-30T18:05:09Z", "Africa/Tripoli")).toBe("20:05:09");
  });
});
