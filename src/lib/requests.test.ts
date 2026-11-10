import { describe, expect, it } from "vitest";
import {
  clampLeaveDates,
  customKindsOf,
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
import { ERROR_TEXT, toKnownCode } from "./errors";
import { submitArgs } from "./supabaseApi";
import type { ApprovalStep, CustomKind, DateMode, RequestItem } from "./types";

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

// ---------------------------------------------------------------- custom request kinds (phase 24)

describe("custom request kinds", () => {
  const today = "2026-11-02";
  const balance = { leave_type: "custom" as const, entitled: 10, used: 0, pending: 0, remaining: 10 };
  const leaveKind: CustomKind = { id: "k1", family: "leave", name: "حج", sort_order: 1, gender: "all", reason_required: false, date_mode: null, balance };
  const reasonKind: CustomKind = { ...leaveKind, id: "k2", name: "دراسة", reason_required: true };
  const otherKind = (mode: DateMode, id = "k3"): CustomKind => ({ id, family: "other", name: "سلفة", sort_order: 3, gender: "all", reason_required: false, date_mode: mode, balance: null });
  const kinds = [leaveKind, reasonKind, otherKind("single")];

  it("a request is titled with the name of its kind", () => {
    expect(requestTitle({ type: "leave", leave_type: "custom", kind_name: "حج" })).toBe("إجازة حج");
    expect(requestTitle({ type: "other", leave_type: null, kind_name: "سلفة" })).toBe("سلفة");
  });
  it("a kind name that already starts with «إجازة» is not prefixed twice", () => {
    expect(requestTitle({ type: "leave", leave_type: "custom", kind_name: "إجازة حج" })).toBe("إجازة حج");
  });
  it("without a kind name: a custom leave reads «إجازة خاصة», a plain other stays «طلب آخر», built-ins are unchanged", () => {
    expect(requestTitle({ type: "leave", leave_type: "custom", kind_name: null })).toBe("إجازة خاصة");
    expect(requestTitle({ type: "leave", leave_type: "custom" })).toBe("إجازة خاصة");
    expect(requestTitle({ type: "other", leave_type: null, kind_name: null })).toBe("طلب آخر");
    expect(requestTitle({ type: "leave", leave_type: "sick" })).toBe("إجازة مرضية");
    expect(requestTitle({ type: "permission", leave_type: null, permission_type: "خروج" })).toBe("إذن: خروج");
  });

  it("customKindsOf: the kinds of one family; an older database sends none", () => {
    expect(customKindsOf({}, "leave")).toEqual([]);
    expect(customKindsOf({ custom_kinds: undefined }, "other")).toEqual([]);
    expect(customKindsOf({ custom_kinds: kinds }, "leave").map((k) => k.id)).toEqual(["k1", "k2"]);
    expect(customKindsOf({ custom_kinds: kinds }, "other").map((k) => k.id)).toEqual(["k3"]);
  });

  it("emptyDraft has no kind", () => {
    expect(emptyDraft(today).custom_kind_id).toBe("");
  });

  it("custom leave: leave_type custom, the kind id, the same dates as a built-in leave", () => {
    const r = draftToRequest({ ...emptyDraft(today), custom_kind_id: "k1", start_date: "2026-11-10", end_date: "2026-11-12", reason: "  " }, TZ, kinds);
    expect(r).toEqual({ ok: true, request: { type: "leave", leave_type: "custom", custom_kind_id: "k1", start_date: "2026-11-10", end_date: "2026-11-12", reason: null } });
  });
  it("custom leave: a kind that needs a reason is not sent without one", () => {
    const d = { ...emptyDraft(today), custom_kind_id: "k2", start_date: "2026-11-10", end_date: "2026-11-10" };
    expect(draftToRequest({ ...d, reason: " " }, TZ, kinds)).toEqual({ ok: false, error: "reason_required" });
    expect(draftToRequest({ ...d, reason: "امتحان" }, TZ, kinds).ok).toBe(true);
  });
  it("custom leave: a kind that is not in the list (or of the other family) is refused before sending", () => {
    expect(draftToRequest({ ...emptyDraft(today), custom_kind_id: "gone" }, TZ, kinds)).toEqual({ ok: false, error: "custom_kind_not_found" });
    expect(draftToRequest({ ...emptyDraft(today), custom_kind_id: "k3" }, TZ, kinds)).toEqual({ ok: false, error: "custom_kind_not_found" });
    expect(draftToRequest({ ...emptyDraft(today), custom_kind_id: "k1" }, TZ)).toEqual({ ok: false, error: "custom_kind_not_found" });
  });
  it("custom leave: dates and the year rule are still checked", () => {
    expect(draftToRequest({ ...emptyDraft(today), custom_kind_id: "k1", start_date: "2026-11-12", end_date: "2026-11-10" }, TZ, kinds)).toEqual({ ok: false, error: "invalid_dates" });
    expect(draftToRequest({ ...emptyDraft(today), custom_kind_id: "k1", start_date: "2026-12-30", end_date: "2027-01-02" }, TZ, kinds)).toEqual({ ok: false, error: "crosses_year" });
  });
  it("a built-in leave is unchanged: no kind id in the request", () => {
    const r = draftToRequest({ ...emptyDraft(today), start_date: "2026-11-10", end_date: "2026-11-10" }, TZ, kinds);
    expect(r.ok && r.request).not.toHaveProperty("custom_kind_id");
    expect(r.ok && r.request).toMatchObject({ leave_type: "annual" });
  });

  const otherDraft = (over: object = {}) => ({ ...emptyDraft(today), type: "other" as const, custom_kind_id: "k3", start_date: "2026-11-10", end_date: "2026-11-12", reason: "سلفة 500", ...over });
  it("custom other, one day: the end is the start", () => {
    expect(draftToRequest(otherDraft(), TZ, kinds)).toEqual({ ok: true, request: { type: "other", custom_kind_id: "k3", start_date: "2026-11-10", end_date: "2026-11-10", reason: "سلفة 500" } });
  });
  it("custom other, no date: both dates are the chosen start (the server stores today)", () => {
    const k = [otherKind("none")];
    expect(draftToRequest(otherDraft({ start_date: "2026-11-02", end_date: "2026-11-05" }), TZ, k)).toEqual({ ok: true, request: { type: "other", custom_kind_id: "k3", start_date: "2026-11-02", end_date: "2026-11-02", reason: "سلفة 500" } });
  });
  it("custom other, a period: the dates go as they are, and a reversed period is caught", () => {
    const k = [otherKind("range")];
    expect(draftToRequest(otherDraft(), TZ, k)).toEqual({ ok: true, request: { type: "other", custom_kind_id: "k3", start_date: "2026-11-10", end_date: "2026-11-12", reason: "سلفة 500" } });
    expect(draftToRequest(otherDraft({ start_date: "2026-11-12", end_date: "2026-11-10" }), TZ, k)).toEqual({ ok: false, error: "invalid_dates" });
  });
  it("custom other, one day or no date: a leftover end date before the start does not block the request (the field is not shown)", () => {
    for (const mode of ["single", "none"] as const) {
      const r = draftToRequest(otherDraft({ start_date: "2026-11-10", end_date: "2026-11-01" }), TZ, [otherKind(mode)]);
      expect(r).toEqual({ ok: true, request: { type: "other", custom_kind_id: "k3", start_date: "2026-11-10", end_date: "2026-11-10", reason: "سلفة 500" } });
    }
  });
  it("custom other: the reason is required as for any other request; an unknown kind is refused", () => {
    expect(draftToRequest(otherDraft({ reason: " " }), TZ, kinds)).toEqual({ ok: false, error: "reason_required" });
    expect(draftToRequest(otherDraft({ custom_kind_id: "gone" }), TZ, kinds)).toEqual({ ok: false, error: "custom_kind_not_found" });
    expect(draftToRequest(otherDraft({ custom_kind_id: "k1" }), TZ, kinds)).toEqual({ ok: false, error: "custom_kind_not_found" });
  });
  it("a plain other request is unchanged", () => {
    const r = draftToRequest({ ...emptyDraft(today), type: "other", start_date: "2026-11-10", end_date: "2026-11-12", reason: "شهادة راتب" }, TZ, kinds);
    expect(r).toEqual({ ok: true, request: { type: "other", start_date: "2026-11-10", end_date: "2026-11-12", reason: "شهادة راتب" } });
  });

  it("two kinds are two different requests for the preview", () => {
    const a = draftToRequest({ ...emptyDraft(today), custom_kind_id: "k1" }, TZ, kinds);
    const b = draftToRequest({ ...emptyDraft(today), custom_kind_id: "k2", reason: "س" }, TZ, kinds);
    if (!a.ok || !b.ok) throw new Error("drafts should be valid");
    expect(requestSignature(a.request)).not.toBe(requestSignature(b.request));
  });

  it("server arguments: the kind id goes with a custom leave and a custom other", () => {
    const leave = submitArgs("k", { type: "leave", leave_type: "custom", custom_kind_id: "k1", start_date: "2026-11-10", end_date: "2026-11-11", reason: null }, false);
    expect(leave).toMatchObject({ p_type: "leave", p_leave_type: "custom", p_custom_kind_id: "k1", p_permission_type_id: null });
    const other = submitArgs("k", { type: "other", custom_kind_id: "k3", start_date: "2026-11-10", end_date: "2026-11-10", reason: "x" }, false);
    expect(other).toMatchObject({ p_type: "other", p_leave_type: null, p_custom_kind_id: "k3" });
  });
  it("server arguments: built-ins and permissions do not send the parameter at all (a database before phase 24 does not know it)", () => {
    const leave = submitArgs("k", { type: "leave", leave_type: "sick", start_date: "2026-11-10", end_date: "2026-11-11", reason: null }, true);
    const other = submitArgs("k", { type: "other", start_date: "2026-11-10", end_date: "2026-11-10", reason: "x" }, false);
    const perm = submitArgs("k", { type: "permission", permission_type_id: "t1", start_at: null, end_at: "2026-11-05T08:00:00.000Z", reason: null }, false);
    for (const a of [leave, other, perm]) expect(a).not.toHaveProperty("p_custom_kind_id");
  });

  it("the three new refusals have their own text", () => {
    const texts: Record<string, string> = {
      custom_kind_not_found: "هذا النوع لم يعد متاحاً.",
      custom_kind_disabled: "هذا النوع متوقف حالياً.",
      kind_gender_mismatch: "هذا النوع غير متاح لهذا الحساب.",
    };
    for (const [code, text] of Object.entries(texts)) {
      expect(toKnownCode(code)).toBe(code);
      expect(ERROR_TEXT[code as keyof typeof ERROR_TEXT]).toBe(text);
    }
  });
});
