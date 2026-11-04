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
