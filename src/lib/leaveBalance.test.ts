import { describe, expect, it } from "vitest";
import { annualCard, chargedLine, overBalanceLine } from "./leaveBalance";
import type { LeaveBalance } from "./types";

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
