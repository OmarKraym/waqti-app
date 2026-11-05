import { describe, expect, it } from "vitest";
import {
  clampLeaveDates,
  leaveEarliest,
  addDays,
  draftToRequest,
  emptyDraft,
  formatDays,
  formatMinutes,
  formatPeriod,
  formatTimes,
  localDate,
  permissionLeft,
  permissionTimesFilled,
  progressLine,
  visibleNote,
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
    expect(p.time).toBe("10:00 ص – 12:30 م");
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
    expect(requestTitle({ type: "permission", leave_type: null, permission_type: "تبرير تأخير" })).toBe("إذن: تبرير تأخير");
  });
});

describe("balances", () => {
  it("remaining after a request (null = not limited)", () => {
    expect(remainingAfter({ leave_type: "annual", entitled: 30, used: 5, pending: 2, remaining: 23 }, 3)).toBe(20);
    expect(remainingAfter({ leave_type: "sick", entitled: null, used: 0, pending: 0, remaining: null }, 3)).toBeNull();
    expect(remainingAfter(null, 3)).toBeNull();
  });

  const pt = { id: "t", name: "خروج", mode: "range" as const, max_per_month: 3, max_minutes: 120, days_back: 7, days_ahead: 30, month: "2026-11", used: 0, pending: 0 };

  it("permission left counts pending requests, never below zero, null when unlimited", () => {
    expect(permissionLeft({ ...pt, used: 1, pending: 1 })).toBe(1);
    expect(permissionLeft({ ...pt, used: 2, pending: 2 })).toBe(0);
    expect(permissionLeft({ ...pt, max_per_month: null, used: 9 })).toBeNull();
  });

  it("times in Arabic", () => {
    expect([1, 2, 3, 11].map(formatTimes)).toEqual(["مرة واحدة", "مرتان", "3 مرات", "11 مرة"]);
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

  it("leave recorded for a day the administration made annual leave", () => {
    expect(progressLine({ status: "approved", steps: [], company_leave_day_id: "x" })).toBe("سجّلتها الإدارة (إجازة سنوية من الإدارة)");
    expect(progressLine({ status: "cancelled", steps: [], company_leave_day_id: "x" })).toBe("ألغتها الإدارة");
  });

  it("a cancelled request says who cancelled it: him, or the administration (a note is saved only then)", () => {
    expect(progressLine({ status: "cancelled", steps: [] })).toBe("ألغيته");
    expect(progressLine({ status: "cancelled", steps: [], decision_note: null })).toBe("ألغيته");
    expect(progressLine({ status: "cancelled", steps: [], decision_note: "أُلغيت إجازتك بسبب تسجيل حضورك يوم 2026-11-02" })).toBe("ألغته الإدارة");
  });

  it("the note under a request: a reason when rejected or cancelled, and on an approved leave the note about the days the administration cancelled", () => {
    const cut = "أُلغيت أيام من إجازتك (2026-11-04) بسبب تسجيل حضورك يوم 2026-11-04";
    expect(visibleNote({ status: "approved", decision_note: cut })).toBe(cut);
    expect(visibleNote({ status: "rejected", decision_note: "ضغط عمل" })).toBe("ضغط عمل");
    expect(visibleNote({ status: "cancelled", decision_note: cut })).toBe(cut);
    expect(visibleNote({ status: "approved", decision_note: null })).toBeNull();
    expect(visibleNote({ status: "approved", decision_note: "   " })).toBeNull();
    expect(visibleNote({ status: "pending", decision_note: "x" })).toBeNull();
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

  const permDraft = (mode: "range" | "late_arrival" | "early_leave", over: object = {}) =>
    ({ ...emptyDraft(today), type: "permission" as const, permission_type_id: "t1", permission_mode: mode, date: "2026-11-05", ...over });

  it("permission (range): from and to become instants in the company time zone", () => {
    const r = draftToRequest(permDraft("range", { from: "10:00", to: "12:00" }), TZ);
    expect(r).toEqual({ ok: true, request: { type: "permission", permission_type_id: "t1", start_at: "2026-11-05T08:00:00.000Z", end_at: "2026-11-05T10:00:00.000Z", reason: null } });
  });

  it("permission (late arrival): only the arrival time is sent; the server starts it at the shift start", () => {
    const r = draftToRequest(permDraft("late_arrival", { to: "08:20", from: "" }), TZ);
    expect(r).toEqual({ ok: true, request: { type: "permission", permission_type_id: "t1", start_at: null, end_at: "2026-11-05T06:20:00.000Z", reason: null } });
  });

  it("permission (final exit): only the exit time is sent; the server ends it at the shift end", () => {
    const r = draftToRequest(permDraft("early_leave", { from: "14:00", to: "" }), TZ);
    expect(r).toEqual({ ok: true, request: { type: "permission", permission_type_id: "t1", start_at: "2026-11-05T12:00:00.000Z", end_at: null, reason: null } });
  });

  it("permission: missing or reversed times, or no type, are not sent", () => {
    expect(draftToRequest(permDraft("range", { from: "10:00", to: "" }), TZ).ok).toBe(false);
    expect(draftToRequest(permDraft("range", { from: "12:00", to: "10:00" }), TZ)).toEqual({ ok: false, error: "invalid_dates" });
    expect(draftToRequest(permDraft("late_arrival", { to: "" }), TZ).ok).toBe(false);
    expect(draftToRequest(permDraft("range", { permission_type_id: "", from: "10:00", to: "11:00" }), TZ)).toEqual({ ok: false, error: "permission_type_not_found" });
  });

  it("the times a mode needs", () => {
    expect(permissionTimesFilled(permDraft("late_arrival", { to: "08:10", from: "" }))).toBe(true);
    expect(permissionTimesFilled(permDraft("early_leave", { from: "", to: "16:00" }))).toBe(false);
    expect(permissionTimesFilled(permDraft("range", { from: "10:00", to: "" }))).toBe(false);
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
      p_start_at: null, p_end_at: null, p_reason: null, p_dry_run: true, p_permission_type_id: null,
    });
  });

  it("permission sends instants and its type, not dates", () => {
    const a = submitArgs("k", { type: "permission", permission_type_id: "t1", start_at: "2026-11-05T08:00:00.000Z", end_at: null, reason: "x" }, false);
    expect(a).toMatchObject({ p_type: "permission", p_leave_type: null, p_start_date: null, p_start_at: "2026-11-05T08:00:00.000Z",
                              p_end_at: null, p_dry_run: false, p_permission_type_id: "t1" });
  });
});

// Keeps the RequestItem shape honest with what the server's request_json returns.
export const sample: RequestItem = {
  id: "r1", type: "leave", leave_type: "annual", status: "pending", start_at: "", end_at: "", days: 3, minutes: null,
  reason: null, decision_note: null, decided_at: null, created_at: "", current_step: 1,
  employee: { full_name: "", employee_number: null, department: null, job_title: null }, steps: [],
};

describe("when a leave may start", () => {
  const today = "2026-11-02";
  it("the company rule decides; without it the old 30 days back apply", () => {
    expect(leaveEarliest({ today, leave_earliest: "2026-11-02" })).toBe("2026-11-02");
    expect(leaveEarliest({ today, leave_earliest: "2026-11-04" })).toBe("2026-11-04");
    expect(leaveEarliest({ today })).toBe("2026-10-03");
  });
  it("a start before the earliest day moves to it, and the end never ends before the start", () => {
    const d = { ...emptyDraft(today), start_date: "2026-11-01", end_date: "2026-11-01" };
    expect(clampLeaveDates(d, "2026-11-02")).toMatchObject({ start_date: "2026-11-02", end_date: "2026-11-02" });
    expect(clampLeaveDates({ ...d, end_date: "2026-11-09" }, "2026-11-04")).toMatchObject({ start_date: "2026-11-04", end_date: "2026-11-09" });
  });
  it("a valid start, or a request that is not a leave, is left alone", () => {
    const ok = { ...emptyDraft(today), start_date: "2026-11-05", end_date: "2026-11-06" };
    expect(clampLeaveDates(ok, "2026-11-02")).toBe(ok);
    const perm = { ...emptyDraft(today), type: "permission" as const, start_date: "2026-10-01" };
    expect(clampLeaveDates(perm, "2026-11-02")).toBe(perm);
  });
});
