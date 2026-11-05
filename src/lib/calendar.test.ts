import { describe, expect, it } from "vitest";
import { holidayBanner, loadCalendar, offLabel, saveCalendar } from "./calendar";
import { groupSchedule } from "./profileSummary";
import { windowText } from "./punchWindow";

const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) }; };

describe("company calendar on the phone", () => {
  it("weekly day off uses the company's label (default «عطلة»)", () => {
    expect(offLabel({ weekly_off_label: "عطلة رسمية", holidays: [], today_holiday: null })).toBe("عطلة رسمية");
    expect(offLabel(null)).toBe("عطلة");
  });
  it("today's holiday banner, or nothing", () => {
    expect(holidayBanner({ weekly_off_label: "x", holidays: [], today_holiday: "عيد الاستقلال" })).toBe("اليوم عطلة رسمية: عيد الاستقلال");
    expect(holidayBanner({ weekly_off_label: "x", holidays: [], today_holiday: null })).toBeNull();
    expect(holidayBanner(null)).toBeNull();
  });
  it("is saved per account and survives bad storage", () => {
    const st = mem();
    saveCalendar("u1", { weekly_off_label: "يوم راحة", holidays: [], today_holiday: null }, st);
    expect(loadCalendar("u1", st)?.weekly_off_label).toBe("يوم راحة");
    expect(loadCalendar("u2", st)).toBeNull();
    st.setItem("waqti-calendar:u3", "{bad");
    expect(loadCalendar("u3", st)).toBeNull();
  });
});

describe("the label is used where the app names the weekly day off", () => {
  it("schedule in «ملخص بياناتي»", () => {
    expect(groupSchedule([{ weekday: 5, is_workday: false, start_time: null, end_time: null }], "عطلة رسمية")).toEqual([{ days: "الجمعة", hours: "عطلة رسمية" }]);
  });
  it("the line under the punch button", () => {
    expect(windowText({ allowed: false, opens_at: null, closes_at: null, reason: "day_off" }, "Africa/Tripoli", "عطلة رسمية")).toBe("اليوم عطلة رسمية");
  });
});

import { holidayItems } from "./calendar";
describe("holiday list on Home (active and cancelled, until the date has passed)", () => {
  const cal = {
    weekly_off_label: "عطلة رسمية", today_holiday: null,
    holidays: [
      { name: "عيد الاستقلال", start_date: "2026-12-24", end_date: "2026-12-24", repeats_yearly: true, cancelled: false },
      { name: "عطلة مُلغاة", start_date: "2026-11-10", end_date: "2026-11-11", repeats_yearly: false, cancelled: true },
      { name: "انتهت", start_date: "2026-11-01", end_date: "2026-11-02", repeats_yearly: false, cancelled: false },
      { name: "اليوم", start_date: "2026-11-04", end_date: "2026-11-04", repeats_yearly: false, cancelled: false },
    ],
  };
  it("drops the past, keeps cancelled ones, sorted by date", () => {
    const items = holidayItems(cal, "2026-11-04");
    expect(items.map((i) => i.name)).toEqual(["اليوم", "عطلة مُلغاة", "عيد الاستقلال"]);
  });
  it("says what each one is", () => {
    const [today, cancelled, yearly] = holidayItems(cal, "2026-11-04");
    expect(today.when).toBe("اليوم · 04/11/2026");
    expect(cancelled.cancelled).toBe(true);
    expect(cancelled.note).toBe("أُلغيت — الدوام كالمعتاد");
    expect(cancelled.when).toBe("10/11/2026 – 11/11/2026");
    expect(yearly.note).toBe("كل سنة");
    expect(yearly.when).toBe("24/12/2026");
  });
  it("tomorrow", () => expect(holidayItems(cal, "2026-12-23").find((i) => i.name === "عيد الاستقلال")?.when).toBe("غدًا · 24/12/2026"));
  it("annual leave days set by the administration say their rules", () => {
    const c = {
      weekly_off_label: null, today_holiday: null,
      holidays: [
        { kind: "annual_leave" as const, name: "جسر العيد", start_date: "2026-11-12", end_date: "2026-11-12", scope: "absent" as const,
          worked_rule: "no_deduct" as const, short_rule: "negative" as const, cancelled: false },
        { kind: "annual_leave" as const, name: "الخميس", start_date: "2026-11-19", end_date: "2026-11-19", scope: "all" as const,
          worked_rule: "deduct_overtime" as const, short_rule: "unpaid" as const, cancelled: false },
        { kind: "annual_leave" as const, name: "ملغاة", start_date: "2026-11-20", end_date: "2026-11-20", scope: "all" as const,
          worked_rule: "deduct" as const, short_rule: "negative" as const, cancelled: true },
      ],
    };
    const [a, b, x] = holidayItems(c, "2026-11-05");
    expect(a.kind).toBe("annual_leave");
    expect(a.note).toBe("إجازة سنوية لمن لا يحضر ولا يبصم (تُخصم من رصيده)");
    expect(b.note).toBe("إجازة سنوية للجميع (تُخصم من الرصيد) · من يحضر يُحسب وقته عملًا إضافيًا · إن لم يكفِ رصيدك: بدون راتب");
    expect(x.note).toBe("أُلغيت — الدوام كالمعتاد");
  });
  it("nothing -> empty", () => expect(holidayItems(null, "2026-11-04")).toEqual([]));
});
