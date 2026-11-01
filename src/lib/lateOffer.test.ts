import { describe, expect, it } from "vitest";
import { lateCandidate } from "./lateOffer";
import type { PermissionUsage, RequestItem, RequestsOverview } from "./types";

const TZ = "Africa/Tripoli"; // UTC+2
const PUNCH = "2026-11-03T06:40:00Z"; // 08:40 in Tripoli

const lateType = (over: Partial<PermissionUsage> = {}): PermissionUsage => ({
  id: "pt-late", name: "تبرير تأخير", mode: "late_arrival", max_per_month: 3, max_minutes: 60,
  days_back: 0, days_ahead: 0, month: "2026-11", used: 0, pending: 0, ...over,
});
const exitType: PermissionUsage = { ...lateType(), id: "pt-exit", name: "خروج", mode: "range" };

const request = (over: Partial<RequestItem>): RequestItem => ({
  id: "r1", type: "permission", leave_type: null, permission_type_id: "pt-late", permission_type: "تبرير تأخير",
  status: "pending", start_at: "2026-11-03T06:00:00Z", end_at: PUNCH, days: null, minutes: 40, reason: null,
  decision_note: null, decided_at: null, created_at: "2026-11-03T06:41:00Z", current_step: 1,
  employee: { full_name: "x", employee_number: null, department: null, job_title: null }, steps: [], ...over,
});

const overview = (types: PermissionUsage[], requests: RequestItem[] = []): RequestsOverview =>
  ({ balances: [], permission_types: types, requests, today: "2026-11-03", timezone: TZ, inbox_count: 0 }) as RequestsOverview;

describe("offer a late-arrival justification after a late check-in", () => {
  it("offers it, with the arrival time of the punch on the company clock", () => {
    const c = lateCandidate(overview([exitType, lateType()]), PUNCH, TZ);
    expect(c?.ptype.id).toBe("pt-late");
    expect(c?.draft).toMatchObject({ type: "permission", permission_type_id: "pt-late", permission_mode: "late_arrival", date: "2026-11-03", to: "08:40" });
  });

  it("no offer when the company has no late-arrival permission", () => {
    expect(lateCandidate(overview([exitType]), PUNCH, TZ)).toBeNull();
  });

  it("no offer when this month's allowance is used up (pending ones count)", () => {
    expect(lateCandidate(overview([lateType({ used: 2, pending: 1 })]), PUNCH, TZ)).toBeNull();
    expect(lateCandidate(overview([lateType({ used: 3 })]), PUNCH, TZ)).toBeNull();
  });

  it("offered while one is still left, and when there is no limit", () => {
    expect(lateCandidate(overview([lateType({ used: 1, pending: 1 })]), PUNCH, TZ)).not.toBeNull();
    expect(lateCandidate(overview([lateType({ max_per_month: null, used: 40 })]), PUNCH, TZ)).not.toBeNull();
  });

  it("no offer when a justification for today is already waiting or approved", () => {
    expect(lateCandidate(overview([lateType()], [request({ status: "pending" })]), PUNCH, TZ)).toBeNull();
    expect(lateCandidate(overview([lateType()], [request({ status: "approved" })]), PUNCH, TZ)).toBeNull();
  });

  it("a rejected or cancelled one, or one for another day, does not block the offer", () => {
    expect(lateCandidate(overview([lateType()], [request({ status: "rejected" }), request({ id: "r2", status: "cancelled" })]), PUNCH, TZ)).not.toBeNull();
    const yesterday = request({ start_at: "2026-11-02T06:00:00Z", end_at: "2026-11-02T06:40:00Z", status: "approved" });
    expect(lateCandidate(overview([lateType()], [yesterday]), PUNCH, TZ)).not.toBeNull();
  });

  it("a request of another permission type today does not block it", () => {
    expect(lateCandidate(overview([lateType(), exitType], [request({ permission_type_id: "pt-exit" })]), PUNCH, TZ)).not.toBeNull();
  });
});
