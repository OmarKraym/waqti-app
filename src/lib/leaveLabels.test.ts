import { describe, expect, it } from "vitest";
import { ERROR_TEXT } from "./errors";
import { LEAVE_LABEL, requestTitle } from "./requests";

// The admin panel is the source of truth for the leave-type words. The same map is pinned in the panel
// (tests/leave-labels.test.mjs) and in the database notification text (supabase/tests/leave_labels_tests.sql).
describe("leave-type labels", () => {
  it("are exactly the panel's words", () => {
    expect(LEAVE_LABEL).toEqual({
      annual: "سنوية",
      sick: "مرضية",
      emergency: "اضطرارية",
      marriage: "زواج",
      maternity: "وضع",
      unpaid: "بدون راتب",
      custom: "خاصة",
    });
  });

  it("titles an emergency and a maternity leave with them", () => {
    const base = { id: "r", type: "leave", status: "pending", start_at: "", end_at: "", steps: [] } as never;
    expect(requestTitle({ ...(base as object), leave_type: "emergency" } as never)).toBe("إجازة اضطرارية");
    expect(requestTitle({ ...(base as object), leave_type: "maternity" } as never)).toBe("إجازة وضع");
  });

  it("names the maternity leave the same way in its error", () => {
    expect(ERROR_TEXT.maternity_female_only).toBe("إجازة الوضع غير متاحة لهذا الحساب.");
  });
});
