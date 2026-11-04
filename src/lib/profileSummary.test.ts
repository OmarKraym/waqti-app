import { describe, expect, it } from "vitest";
import { groupSchedule, loadSummary, money, saveSummary, serviceLength, summaryGroups } from "./profileSummary";
import type { ProfileSummary } from "./types";

describe("serviceLength: time since hiring", () => {
  const today = new Date("2026-11-04T10:00:00");
  it("years and months", () => expect(serviceLength("2022-03-01", today)).toBe("4 سنوات و 8 أشهر"));
  it("one year exactly", () => expect(serviceLength("2025-11-04", today)).toBe("سنة"));
  it("two years, one month", () => expect(serviceLength("2024-10-01", today)).toBe("سنتان وشهر"));
  it("months only", () => expect(serviceLength("2026-08-20", today)).toBe("شهران"));
  it("under a month", () => expect(serviceLength("2026-10-20", today)).toBe("أقل من شهر"));
  it("future or bad date -> nothing", () => {
    expect(serviceLength("2027-01-01", today)).toBeNull();
    expect(serviceLength("x", today)).toBeNull();
  });
});

describe("groupSchedule: same hours on following days become one range (Saturday first)", () => {
  const day = (weekday: number, start: string | null, end: string | null) => ({ weekday, is_workday: !!start, start_time: start, end_time: end });
  it("Sat-Wed same hours, Thursday short, Friday off", () => {
    const rows = [day(0, "08:00", "16:00"), day(1, "08:00", "16:00"), day(2, "08:00", "16:00"), day(3, "08:00", "16:00"),
      day(4, "08:00", "13:00"), day(5, null, null), day(6, "08:00", "16:00")];
    expect(groupSchedule(rows)).toEqual([
      { days: "السبت – الأربعاء", hours: "08:00–16:00" },
      { days: "الخميس", hours: "08:00–13:00" },
      { days: "الجمعة", hours: "إجازة" },
    ]);
  });
  it("two separate days with the same hours are not joined", () => {
    const rows = [day(6, "08:00", "12:00"), day(0, null, null), day(1, "08:00", "12:00")];
    expect(groupSchedule(rows)).toEqual([
      { days: "السبت", hours: "08:00–12:00" },
      { days: "الأحد", hours: "إجازة" },
      { days: "الإثنين", hours: "08:00–12:00" },
    ]);
  });
  it("empty -> empty", () => expect(groupSchedule([])).toEqual([]));
});

describe("money", () => {
  it("LYD with up to 3 decimals", () => {
    expect(money(1500)).toBe("1,500 د.ل");
    expect(money(1750.5)).toBe("1,750.5 د.ل");
  });
});

describe("summaryGroups: what the profile draws", () => {
  const today = new Date("2026-11-04T10:00:00");
  it("defaults (no salary, no personal) -> job, schedule, leave", () => {
    const s: ProfileSummary = {
      employee: { department: "المبيعات", job_title: null, work_location_name: "المقر", hire_date: "2022-03-01" },
      schedule: [{ weekday: 6, is_workday: true, start_time: "08:00", end_time: "16:00" }],
      leave: [{ type: "annual", days: 30, is_default: true }, { type: "sick", days: 10, is_default: false }],
    };
    const g = summaryGroups(s, today);
    expect(g.map((x) => x.title)).toEqual(["الوظيفة", "الدوام", "الإجازات"]);
    expect(g[0].rows).toEqual([
      { label: "القسم", value: "المبيعات" },
      { label: "موقع العمل", value: "المقر" },
      { label: "تاريخ التعيين", value: "2022-03-01", note: "4 سنوات و 8 أشهر", ltr: true },
    ]);
    expect(g[2].rows).toEqual([{ label: "سنوية", value: "30 يومًا" }, { label: "مرضية", value: "10 أيام" }]);
  });
  it("salary parts are independent; total alone is fine", () => {
    const g = summaryGroups({ salary: { total: 1750 } }, today);
    expect(g).toEqual([{ title: "الراتب", rows: [{ label: "إجمالي الراتب", value: "1,750 د.ل", ltr: true, strong: true }] }]);
    const g2 = summaryGroups({ salary: { base_salary: 1500, components: [{ name: "بدل سكن", amount: 200 }] } }, today);
    expect(g2[0].rows.map((r) => r.label)).toEqual(["الراتب الأساسي", "بدل سكن"]);
  });
  it("personal: birth date and gender in Arabic", () => {
    const g = summaryGroups({ employee: { birth_date: "1990-05-02", gender: "female" } }, today);
    expect(g).toEqual([{ title: "شخصي", rows: [{ label: "تاريخ الميلاد", value: "1990-05-02", ltr: true }, { label: "الجنس", value: "أنثى" }] }]);
  });
  it("nothing visible -> no groups (the section is not drawn)", () => {
    expect(summaryGroups({}, today)).toEqual([]);
    expect(summaryGroups({ employee: { department: null }, schedule: [], leave: [] }, today)).toEqual([]);
  });
});

describe("saved copy on this phone (per account)", () => {
  const mem = () => {
    const m = new Map<string, string>();
    return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) };
  };
  it("saves and reads back with its time", () => {
    const st = mem();
    saveSummary("u1", { leave: [] }, 1000, st);
    expect(loadSummary("u1", st)).toEqual({ data: { leave: [] }, saved_at_ms: 1000 });
    expect(loadSummary("u2", st)).toBeNull();
  });
  it("broken or blocked storage never throws", () => {
    const st = mem();
    st.setItem("waqti-summary:u1", "{bad");
    expect(loadSummary("u1", st)).toBeNull();
    const bad = { getItem: () => { throw new Error("x"); }, setItem: () => { throw new Error("x"); }, removeItem: () => undefined };
    expect(() => saveSummary("u1", {}, 1, bad)).not.toThrow();
    expect(loadSummary("u1", bad)).toBeNull();
  });
});
