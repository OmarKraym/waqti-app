import { describe, expect, it } from "vitest";
import { lateNote, lateOfferFrom, shouldAskLateStatus } from "./lateOffer";
import type { LateStatus, PermissionUsage, PunchResult } from "./types";

const TZ = "Africa/Tripoli"; // UTC+2
const PUNCH = "2026-11-03T06:40:00Z"; // 08:40 in Tripoli

const lateType = (over: Partial<PermissionUsage> = {}): PermissionUsage => ({
  id: "pt-late", name: "تبرير تأخير", mode: "late_arrival", max_per_month: 3, max_minutes: 60,
  days_back: 0, days_ahead: 0, month: "2026-11", used: 0, pending: 0, ...over,
});

/** What employee_late_status returns for a 40-minute delay with grace 15 under "all minutes after grace". */
const status = (over: Partial<LateStatus> = {}): LateStatus => ({
  event_id: "ev1", late_min: 40, grace_min: 15, chargeable_min: 40, deduction_min: null, rule: "all_after_grace",
  remaining: 3, offer: true, reason: "offer", permission: lateType(), ...over,
});

describe("lateOfferFrom: the offer comes from the server's decision", () => {
  it("offers a filled-in form: late arrival, today, arrival time = the punch on the company clock", () => {
    const o = lateOfferFrom(status(), PUNCH, TZ);
    expect(o?.draft).toMatchObject({ type: "permission", permission_type_id: "pt-late", permission_mode: "late_arrival", date: "2026-11-03", to: "08:40" });
  });

  it("minutes = the chargeable minutes, left = what the server says is left", () => {
    expect(lateOfferFrom(status({ chargeable_min: 25, late_min: 40, remaining: 2 }), PUNCH, TZ)).toMatchObject({ minutes: 25, left: 2 });
  });

  it("left is null when the type has no monthly limit", () => {
    expect(lateOfferFrom(status({ remaining: null, permission: lateType({ max_per_month: null }) }), PUNCH, TZ)?.left).toBeNull();
  });

  it("every reason other than 'offer' is no offer (including the ones added later)", () => {
    const reasons = ["not_check_in", "day_off", "not_first", "not_late", "within_grace", "no_type", "already", "no_balance", "too_long", "outside_window", "something_new"];
    for (const reason of reasons) {
      expect(lateOfferFrom(status({ offer: false, reason }), PUNCH, TZ), reason).toBeNull();
    }
  });

  it("a status that contradicts itself is no offer (either way round); and no permission type = no form to fill", () => {
    expect(lateOfferFrom(status({ offer: false }), PUNCH, TZ)).toBeNull();
    expect(lateOfferFrom(status({ offer: true, reason: "outside_window" }), PUNCH, TZ)).toBeNull();
    expect(lateOfferFrom(status({ permission: null }), PUNCH, TZ)).toBeNull();
  });

  it("the arrival time uses the company time zone, not the phone's", () => {
    expect(lateOfferFrom(status(), "2026-11-03T22:10:00Z", TZ)?.draft).toMatchObject({ date: "2026-11-04", to: "00:10" });
  });
});

describe("lateNote: one line when no offer is made but the person should know why", () => {
  it("no balance: says the month's justifications are used up", () => {
    const n = lateNote(status({ offer: false, reason: "no_balance", remaining: 0 }));
    expect(n).toContain("40 د");
    expect(n).toContain("استنفدت");
  });

  it("too long: says the longest allowed delay", () => {
    const n = lateNote(status({ offer: false, reason: "too_long", late_min: 90, chargeable_min: 90, permission: lateType({ max_minutes: 60 }) }));
    expect(n).toContain("ساعة و30 د");      // how late he was
    expect(n).toContain("الحد المسموح");     // …and that it is above the longest allowed delay
    expect(n).toContain("(ساعة)");           // the limit itself: 60 minutes
  });

  it("already: says a justification for today exists, and never promises a deduction (it may be excused)", () => {
    const n = lateNote(status({ offer: false, reason: "already", deduction_min: 30 }));
    expect(n).toContain("تبرير");
    expect(n).not.toContain("خصم");
  });

  it("adds the expected deduction when there is one (no balance / too long)", () => {
    expect(lateNote(status({ offer: false, reason: "no_balance", remaining: 0, deduction_min: 30 }))).toContain("الخصم المتوقع: 30 د");
    expect(lateNote(status({ offer: false, reason: "too_long", late_min: 90, chargeable_min: 90, deduction_min: 60 }))).toContain("الخصم المتوقع: ساعة");
    expect(lateNote(status({ offer: false, reason: "no_balance", remaining: 0, deduction_min: 0 }))).not.toContain("خصم");
    expect(lateNote(status({ offer: false, reason: "no_balance", remaining: 0, deduction_min: null }))).not.toContain("خصم");
  });

  it("nothing to say for every other reason, for an offer, and when nothing is chargeable", () => {
    const quiet = ["not_check_in", "day_off", "not_first", "not_late", "within_grace", "no_type", "outside_window", "offer", "something_new"];
    for (const reason of quiet) expect(lateNote(status({ offer: reason === "offer", reason })), reason).toBeNull();
    expect(lateNote(status({ offer: false, reason: "no_balance", remaining: 0, chargeable_min: 0 }))).toBeNull();
  });
});

describe("shouldAskLateStatus: which punches are worth asking the server about", () => {
  const result = (over: Partial<PunchResult> = {}): PunchResult => ({
    event_id: "e1", action: "check_in", server_time: PUNCH, location_status: "inside", needs_review: false, duplicate: false, ...over,
  });

  it("an online check-in: yes", () => {
    expect(shouldAskLateStatus(result())).toBe(true);
    expect(shouldAskLateStatus(result({ needs_review: true, location_status: "outside" }))).toBe(true);
    expect(shouldAskLateStatus(result({ on_approved_leave: true }))).toBe(true);
  });

  it("a duplicate (a retry the server already handled): no", () => {
    expect(shouldAskLateStatus(result({ duplicate: true }))).toBe(false);
  });

  it("a check-out: no", () => {
    expect(shouldAskLateStatus(result({ action: "check_out" }))).toBe(false);
  });

  it("a punch saved on the phone and sent later (the event is not on the server yet / the moment has passed): no", () => {
    expect(shouldAskLateStatus(result({ recorded_offline: true }))).toBe(false);
  });
});
