import { describe, expect, it } from "vitest";
import {
  addDays,
  draftToRequest,
  emptyDraft,
  formatDays,
  formatMinutes,
  formatPeriod,
  localDate,
  permissionLeft,
  progressLine,
  remainingAfter,
  requestSignature,
  requestTitle,
  visibleSteps,
  zonedToUtc,
} from "./requests";
import { submitArgs } from "./supabaseApi";
import type { ApprovalStep, RequestItem } from "./types";

const TZ = "Africa/Tripoli"; // UTC+2, no daylight saving

describe("dates in the company time zone", () => {
  it("wall time in Tripoli -> UTC", () => {
    expect(zonedToUtc("2026-11-03", "10:30", TZ)).toBe("2026-11-03T08:30:00.000Z");
    expect(zonedToUtc("2026-11-03", "00:15", TZ)).toBe("2026-11-02T22:15:00.000Z");
  });

  it("handles a zone with daylight saving (both sides of the change)", () => {
    expect(zonedToUtc("2026-07-01", "09:00", "Europe/Berlin")).toBe("2026-07-01T07:00:00.000Z");
    expect(zonedToUtc("2026-12-01", "09:00", "Europe/Berlin")).toBe("2026-12-01T08:00:00.000Z");
  });

  it("local date of an instant", () => {
    expect(localDate("2026-11-02T22:30:00Z", TZ)).toBe("2026-11-03");
    expect(localDate("2026-11-02T21:30:00Z", TZ)).toBe("2026-11-02");
  });

  it("adds days across months and years", () => {
    expect(addDays("2026-12-30", 3)).toBe("2027-01-02");
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
  });

  it("leave period: the stored end is exclusive", () => {
    const one = formatPeriod({ type: "leave", start_at: "2026-11-02T22:00:00Z", end_at: "2026-11-03T22:00:00Z" }, TZ);
    expect(one.day).toContain("3");
    expect(one.day).not.toContain("4");
    expect(one.time).toBeNull();
    const three = formatPeriod({ type: "leave", start_at: "2026-11-02T22:00:00Z", end_at: "2026-11-05T22:00:00Z" }, TZ);
    expect(three.day).toMatch(/3.*–.*5/);
  });

  it("permission period shows the hours", () => {
    const p = formatPeriod({ type: "permission", start_at: "2026-11-03T08:00:00Z", end_at: "2026-11-03T10:30:00Z" }, TZ);
    expect(p.time).toBe("10:00 – 12:30");
  });
});

describe("wording", () => {
  it("days in Arabic", () => {
    expect([1, 2, 3, 10, 11, 21].map(formatDays)).toEqual(["يوم واحد", "يومان", "3 أيام", "10 أيام", "11 يومًا", "21 يومًا"]);
    expect(formatDays(1.5)).toBe("1.5 يوم");
  });

  it("minutes as hours", () => {
    expect(formatMinutes(45)).toBe("45 د");
    expect(formatMinutes(60)).toBe("ساعة");
    expect(formatMinutes(120)).toBe("ساعتان");
    expect(formatMinutes(90)).toBe("ساعة و30 د");
    expect(formatMinutes(240)).toBe("4 ساعات");
  });

  it("title", () => {
    expect(requestTitle({ type: "leave", leave_type: "sick" })).toBe("إجازة مرضية");
    expect(requestTitle({ type: "permission", leave_type: null })).toBe("إذن");
  });
});

describe("balances", () => {
  it("remaining after a request (null = not limited)", () => {
    expect(remainingAfter({ leave_type: "annual", entitled: 30, used: 5, pending: 2, remaining: 23 }, 3)).toBe(20);
    expect(remainingAfter({ leave_type: "sick", entitled: null, used: 0, pending: 0, remaining: null }, 3)).toBeNull();
    expect(remainingAfter(null, 3)).toBeNull();
  });

  it("permission left counts pending and never goes below zero", () => {
    expect(permissionLeft({ month: "2026-11", limit: 240, used: 60, pending: 30 })).toBe(150);
    expect(permissionLeft({ month: "2026-11", limit: 240, used: 200, pending: 60 })).toBe(0);
  });
});

describe("approval progress", () => {
  const step = (o: number, kind: ApprovalStep["kind"], status: ApprovalStep["status"], name: string | null = null): ApprovalStep =>
    ({ step_order: o, kind, status, approver_name: name, decided_at: null, note: null });

  it("skipped steps are hidden", () => {
    expect(visibleSteps([step(1, "direct_manager", "skipped"), step(2, "hr", "pending")]).map((s) => s.kind)).toEqual(["hr"]);
  });

  it("says who has the request now", () => {
    const r = { status: "pending" as const, steps: [step(1, "direct_manager", "pending", "خالد"), step(2, "hr", "waiting")] };
    expect(progressLine(r)).toBe("بانتظار: المدير المباشر (خالد)");
    const atHr = { status: "pending" as const, steps: [step(1, "direct_manager", "approved", "خالد"), step(2, "hr", "pending")] };
    expect(progressLine(atHr)).toBe("بانتظار: الموارد البشرية");
  });

  it("says who rejected", () => {
    const r = { status: "rejected" as const, steps: [step(1, "direct_manager", "rejected", "خالد"), step(2, "hr", "cancelled")] };
    expect(progressLine(r)).toBe("رفضه: خالد");
  });
});

describe("the form", () => {
  const today = "2026-11-03";

  it("leave: dates go as calendar dates (the server counts working days)", () => {
    const r = draftToRequest({ ...emptyDraft(today), start_date: "2026-11-10", end_date: "2026-11-12", reason: "  سفر " }, TZ);
    expect(r).toEqual({ ok: true, request: { type: "leave", leave_type: "annual", start_date: "2026-11-10", end_date: "2026-11-12", reason: "سفر" } });
  });

  it("leave: end before start, or across two years, is caught before sending", () => {
    expect(draftToRequest({ ...emptyDraft(today), start_date: "2026-11-12", end_date: "2026-11-10" }, TZ)).toEqual({ ok: false, error: "invalid_dates" });
    expect(draftToRequest({ ...emptyDraft(today), start_date: "2026-12-30", end_date: "2027-01-02" }, TZ)).toEqual({ ok: false, error: "crosses_year" });
  });

  it("permission: hours become instants in the company time zone", () => {
    const r = draftToRequest({ ...emptyDraft(today), type: "permission", date: "2026-11-05", from: "10:00", to: "12:00" }, TZ);
    expect(r).toEqual({ ok: true, request: { type: "permission", start_at: "2026-11-05T08:00:00.000Z", end_at: "2026-11-05T10:00:00.000Z", reason: null } });
  });

  it("permission: missing or reversed hours are not sent", () => {
    expect(draftToRequest({ ...emptyDraft(today), type: "permission", from: "10:00", to: "" }, TZ).ok).toBe(false);
    expect(draftToRequest({ ...emptyDraft(today), type: "permission", from: "12:00", to: "10:00" }, TZ)).toEqual({ ok: false, error: "invalid_dates" });
  });

  it("other: a reason is required", () => {
    expect(draftToRequest({ ...emptyDraft(today), type: "other", reason: "  " }, TZ)).toEqual({ ok: false, error: "reason_required" });
    expect(draftToRequest({ ...emptyDraft(today), type: "other", reason: "شهادة راتب" }, TZ).ok).toBe(true);
  });

  it("the preview is not called again just because the reason text changed", () => {
    const a = draftToRequest({ ...emptyDraft(today), reason: "س" }, TZ);
    const b = draftToRequest({ ...emptyDraft(today), reason: "سفر طويل" }, TZ);
    const c = draftToRequest({ ...emptyDraft(today), end_date: "2026-11-04", reason: "سفر طويل" }, TZ);
    if (!a.ok || !b.ok || !c.ok) throw new Error("drafts should be valid");
    expect(requestSignature(a.request)).toBe(requestSignature(b.request));
    expect(requestSignature(b.request)).not.toBe(requestSignature(c.request));
  });
});

describe("server arguments", () => {
  it("leave sends dates, not instants", () => {
    const a = submitArgs("k", { type: "leave", leave_type: "sick", start_date: "2026-11-10", end_date: "2026-11-11", reason: null }, true);
    expect(a).toEqual({
      p_request_key: "k", p_type: "leave", p_leave_type: "sick", p_start_date: "2026-11-10", p_end_date: "2026-11-11",
      p_start_at: null, p_end_at: null, p_reason: null, p_dry_run: true,
    });
  });

  it("permission sends instants, not dates", () => {
    const a = submitArgs("k", { type: "permission", start_at: "2026-11-05T08:00:00.000Z", end_at: "2026-11-05T10:00:00.000Z", reason: "x" }, false);
    expect(a).toMatchObject({ p_type: "permission", p_leave_type: null, p_start_date: null, p_start_at: "2026-11-05T08:00:00.000Z", p_dry_run: false });
  });
});

// Keeps the RequestItem shape honest with what the server's request_json returns.
export const sample: RequestItem = {
  id: "r1", type: "leave", leave_type: "annual", status: "pending", start_at: "", end_at: "", days: 3, minutes: null,
  reason: null, decision_note: null, decided_at: null, created_at: "", current_step: 1,
  employee: { full_name: "", employee_number: null, department: null, job_title: null }, steps: [],
};
