import { describe, expect, it } from "vitest";
import { annualCard, annualExplain, chargedLine, customUsedTexts, kindBalanceLine, overBalanceLine } from "./leaveBalance";
import type { CustomKind, LeaveBalance } from "./types";

const annual = (p: Partial<LeaveBalance>): LeaveBalance => ({ leave_type: "annual", entitled: 30, used: 0, pending: 0, remaining: 25, ...p });

describe("annual balance card", () => {
  it("shows what can be taken now and the whole year", () => {
    const c = annualCard(annual({ entitled: 30, earned: 25, remaining: 22, used: 3, carried: 0 }));
    expect(c.value).toBe(22);
    expect(c.sub).toBe("متاح حتى اليوم · 30 يومًا للسنة كاملة");
    expect(c.stats.map((s) => s.label)).toEqual(["مستخدمة", "قيد الموافقة", "رصيد السنة"]);
  });

  it("shows days carried in from last year", () => {
    const c = annualCard(annual({ entitled: 40, carried: 10, remaining: 30 }));
    expect(c.stats.map((s) => s.label)).toEqual(["مستخدمة", "قيد الموافقة", "مرحّلة من السنة الماضية"]);
    expect(c.stats[2].value).toBe("10 أيام");
  });

  it("older server (no earned field): same card as before", () => {
    const c = annualCard({ leave_type: "annual", entitled: 30, used: 2, pending: 1, remaining: 27 });
    expect(c.value).toBe(27);
    expect(c.sub).toBe("متبقٍ من 30 يومًا");
  });
});

describe("asking for more than the balance", () => {
  it("says how much is available and that a reason is needed", () => {
    expect(overBalanceLine({ days: 7, balance: annual({ remaining: 2 }), over_balance: true }))
      .toBe("طلبك (7 أيام) أكثر من رصيدك المتاح (يومان). اكتب السبب، والإدارة تقرر.");
  });
  it("nothing when within the balance or not known", () => {
    expect(overBalanceLine({ days: 2, balance: annual({ remaining: 5 }), over_balance: false })).toBeNull();
    expect(overBalanceLine(null)).toBeNull();
  });
});

describe("days taken from the balance (set by HR)", () => {
  it("only when HR changed it", () => {
    expect(chargedLine({ type: "leave", days: 7, charged_days: 1.5 })).toBe("خُصم من الرصيد: 1.5 يوم");
    expect(chargedLine({ type: "leave", days: 7, charged_days: 0 })).toBe("خُصم من الرصيد: لا شيء");
    expect(chargedLine({ type: "leave", days: 7, charged_days: null })).toBeNull();
    expect(chargedLine({ type: "leave", days: 7 })).toBeNull();
  });
});

describe("balance of a leave kind the administration added", () => {
  const bal = (p: Partial<LeaveBalance>): LeaveBalance => ({ leave_type: "custom", entitled: 10, used: 0, pending: 0, remaining: 10, ...p });

  it("under the type list: what is left of the days this year", () => {
    expect(kindBalanceLine(bal({ entitled: 10, used: 3, pending: 2, remaining: 5 }))).toBe("المتبقي لك: 5 أيام من 10 أيام هذه السنة.");
    expect(kindBalanceLine(bal({ entitled: 10, remaining: 1 }))).toBe("المتبقي لك: يوم واحد من 10 أيام هذه السنة.");
  });
  it("never shows a negative balance (HR may have charged more than the days)", () => {
    expect(kindBalanceLine(bal({ entitled: 5, used: 7, remaining: -2 }))).toBe("المتبقي لك: لا شيء من 5 أيام هذه السنة.");
  });
  it("unlimited days and no days are said in words", () => {
    expect(kindBalanceLine(bal({ entitled: null, remaining: null }))).toBe("أيام هذا النوع غير محدودة.");
    expect(kindBalanceLine(bal({ entitled: 0, remaining: 0 }))).toBe("لا أيام مخصصة لك من هذا النوع هذه السنة.");
  });
  it("no balance sent (an «other» kind or an older server): no line", () => {
    expect(kindBalanceLine(null)).toBeNull();
  });

  const kind = (name: string, balance: LeaveBalance | null, family: CustomKind["family"] = "leave"): CustomKind =>
    ({ id: name, family, name, sort_order: 1, gender: "all", reason_required: false, date_mode: null, balance });
  it("with the other types of the year: only the kinds used or waiting, with their days", () => {
    const kinds = [
      kind("حج", bal({ used: 3, pending: 1, remaining: 6 })),
      kind("دراسة", bal({ entitled: null, remaining: null })),
      kind("سلفة", null, "other"),
    ];
    expect(customUsedTexts(kinds)).toEqual(["حج: 4 أيام هذه السنة"]);
    expect(customUsedTexts([])).toEqual([]);
  });
});

describe("why the annual balance is what it is (the explanation when the number is tapped)", () => {
  // 30 days a year, 28 November: 332 of 365 days have passed -> 27.29 earned, rounded down to half a day = 27.
  const nov28 = annual({ entitled: 30, earned: 27, carried: 0, used: 0, pending: 0, used_outside: 0, remaining: 27, as_of: "2026-11-28", year: 2026 });

  it("no leave taken: the year is earned day by day, so today is 27 of 30", () => {
    const e = annualExplain(nov28)!;
    expect(e.lead).toBe("رصيدك السنوي 30 يومًا لا يُعطى دفعة واحدة، بل يُكتسب يومًا بيوم على مدار السنة (نحو 2.5 يوم كل شهر).");
    expect(e.rows).toEqual([
      { label: "ما اكتسبته حتى 28 نوفمبر", value: "27 يومًا", sign: "plus" },
      { label: "المتاح لك الآن", value: "27 يومًا", sign: "total" },
    ]);
    expect(e.note).toBe("الباقي (3 أيام) يُضاف تدريجيًا حتى نهاية السنة.");
  });

  it("carried days, used, outside the app and waiting are each one line, and the total matches the card", () => {
    const e = annualExplain(annual({ entitled: 35, earned: 25.5, carried: 5, used: 6, pending: 2, used_outside: 1.5, remaining: 16, as_of: "2026-06-15" }))!;
    expect(e.lead).toContain("رصيدك السنوي 30 يومًا");
    expect(e.rows).toEqual([
      { label: "ما اكتسبته حتى 15 يونيو", value: "20.5 يوم", sign: "plus" },
      { label: "مرحّلة من السنة الماضية", value: "5 أيام", sign: "plus" },
      { label: "مستخدمة", value: "6 أيام", sign: "minus" },
      { label: "سجّلتها الإدارة خارج التطبيق", value: "1.5 يوم", sign: "minus" },
      { label: "قيد الموافقة", value: "يومان", sign: "minus" },
      { label: "المتاح لك الآن", value: "16 يومًا", sign: "total" },
    ]);
    expect(e.note).toBe("الباقي (9.5 يوم) يُضاف تدريجيًا حتى نهاية السنة.");
  });

  it("the whole year earned (31 December): no note about the rest", () => {
    expect(annualExplain(annual({ entitled: 30, earned: 30, carried: 0, remaining: 30, as_of: "2026-12-31" }))!.note).toBeNull();
  });

  it("an older server (no earned field) has nothing to explain: null", () => {
    expect(annualExplain({ leave_type: "annual", entitled: 30, used: 2, pending: 1, remaining: 27 })).toBeNull();
  });
});
