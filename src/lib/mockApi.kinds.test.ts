// The fake server offers and accepts the kinds the administration added (phase 24), like the real one.
import { afterEach, describe, expect, it, vi } from "vitest";
import { localDate } from "./requests";

/** The mock reads its URL flags when the module loads, so each scenario loads a fresh copy. */
async function mockWith(search: string) {
  vi.resetModules();
  vi.stubGlobal("location", { search });
  const mod = await import("./mockApi");
  return mod.createMockApi();
}
afterEach(() => vi.unstubAllGlobals());

const addDays = (d: string, n: number) => new Date(Date.parse(`${d}T12:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

describe("mock server: custom request kinds", () => {
  it("the overview offers the kinds: leave kinds with this employee's days, other kinds with their date mode", async () => {
    const api = await mockWith("");
    const o = await api.getRequestsOverview();
    const kinds = o.custom_kinds ?? [];
    expect(kinds.map((k) => k.name)).toEqual(["حج", "دراسة", "سلفة", "إفادة عمل"]);
    const hajj = kinds.find((k) => k.name === "حج")!;
    expect(hajj).toMatchObject({ family: "leave", reason_required: false, date_mode: null, balance: { leave_type: "custom", entitled: 10, used: 0, pending: 0, remaining: 10 } });
    expect(kinds.find((k) => k.name === "دراسة")).toMatchObject({ reason_required: true, balance: { entitled: null, remaining: null } });
    expect(kinds.find((k) => k.name === "سلفة")).toMatchObject({ family: "other", date_mode: "single", balance: null });
    expect(kinds.find((k) => k.name === "إفادة عمل")).toMatchObject({ family: "other", date_mode: "none", balance: null });
    // the built-in balances are untouched
    expect(o.balances.map((b) => b.leave_type)).toEqual(["annual", "sick", "emergency", "marriage", "unpaid"]);
  });

  it("?kinds=0 plays an older database: no custom_kinds at all", async () => {
    const api = await mockWith("?kinds=0");
    const o = await api.getRequestsOverview();
    expect(o).not.toHaveProperty("custom_kinds");
  });

  it("a custom leave: the preview and the saved request use the kind's days, and the title data is stored", async () => {
    const api = await mockWith("");
    const o = await api.getRequestsOverview();
    const start = addDays(o.today, 7);
    const req = { type: "leave" as const, leave_type: "custom" as const, custom_kind_id: "ck-hajj", start_date: start, end_date: addDays(start, 1), reason: null };
    const preview = await api.previewRequest(req);
    expect(preview.balance).toMatchObject({ leave_type: "custom", entitled: 10 });
    const saved = await api.submitRequest("key-hajj", req);
    expect(saved).toMatchObject({ type: "leave", leave_type: "custom", custom_kind_id: "ck-hajj", kind_name: "حج", status: "pending" });
    const after = (await api.getRequestsOverview()).custom_kinds!.find((k) => k.id === "ck-hajj")!;
    expect(after.balance).toMatchObject({ used: 0, pending: saved.days, remaining: 10 - (saved.days ?? 0) });
  });

  it("a custom leave kind that needs a reason is refused without one", async () => {
    const api = await mockWith("");
    const o = await api.getRequestsOverview();
    const start = addDays(o.today, 7);
    const req = { type: "leave" as const, leave_type: "custom" as const, custom_kind_id: "ck-study", start_date: start, end_date: start, reason: null };
    await expect(api.previewRequest(req)).rejects.toMatchObject({ code: "reason_required" });
  });

  it("a custom «other» without a date is recorded for today whatever dates come; one day keeps only the start", async () => {
    const api = await mockWith("");
    const o = await api.getRequestsOverview();
    const none = await api.submitRequest("key-none", { type: "other", custom_kind_id: "ck-letter", start_date: addDays(o.today, 3), end_date: addDays(o.today, 5), reason: "للسفارة" });
    expect(none).toMatchObject({ type: "other", kind_name: "إفادة عمل", date_mode: "none" });
    expect(localDate(none.start_at, "Africa/Tripoli")).toBe(o.today);
    expect(Date.parse(none.end_at) - Date.parse(none.start_at)).toBe(86_400_000);
    const one = await api.submitRequest("key-one", { type: "other", custom_kind_id: "ck-advance", start_date: addDays(o.today, 3), end_date: addDays(o.today, 9), reason: "سلفة" });
    expect(Date.parse(one.end_at) - Date.parse(one.start_at)).toBe(86_400_000);
  });

  it("an unknown kind, or a kind of the other family, is refused", async () => {
    const api = await mockWith("");
    const o = await api.getRequestsOverview();
    const d = addDays(o.today, 3);
    await expect(api.previewRequest({ type: "leave", leave_type: "custom", custom_kind_id: "gone", start_date: d, end_date: d, reason: null })).rejects.toMatchObject({ code: "custom_kind_not_found" });
    await expect(api.previewRequest({ type: "leave", leave_type: "custom", custom_kind_id: "ck-letter", start_date: d, end_date: d, reason: null })).rejects.toMatchObject({ code: "custom_kind_not_found" });
    await expect(api.previewRequest({ type: "other", custom_kind_id: "ck-hajj", start_date: d, end_date: d, reason: "x" })).rejects.toMatchObject({ code: "custom_kind_not_found" });
  });

  it("?requests=1 adds a custom leave and a dateless «other» to my list", async () => {
    const api = await mockWith("?requests=1");
    const names = (await api.getRequestsOverview()).requests.map((r) => r.kind_name).filter(Boolean);
    expect(names.sort()).toEqual(["إفادة عمل", "حج"]);
  });
});
