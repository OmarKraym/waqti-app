import { formatTime } from "../../lib/attendance";
import type { CardRow } from "../../lib/timecard";
import type { LocationStatus } from "../../lib/types";
import { Icon } from "../../components";

const STATUS_TEXT: Partial<Record<LocationStatus, string>> = {
  outside: "خارج النطاق",
  unavailable: "بدون موقع",
  inaccurate: "دقة ضعيفة",
};

/** A check-out with no check-in before it (the employee forgot to check in). */
function noCheckIn(rows: CardRow[], i: number): boolean {
  return rows[i].action === "check_out" && rows[i].kind === "stamped" && (i === 0 || rows[i - 1].action === "check_out");
}

/** Today's card: one cell per punch. Confirmed times in their colour; saved-on-the-phone ones grey and dashed. */
export function Timecard({ rows, timeZone, freshId }: { rows: CardRow[]; timeZone: string; freshId: string | null }) {
  return (
    <section className="timecard" aria-label="بطاقة اليوم">
      <h3 className="timecard__day">سجل اليوم</h3>
      <ol className="timecard__slots">
        {rows.map((r, i) => (
          <li key={r.key} className={`slot slot--${r.action === "check_in" ? "in" : "out"}`}>
            <span className="slot__label">{r.action === "check_in" ? "حضور" : "انصراف"}</span>
            {r.kind === "empty" ? (
              <span className="slot__empty" role="img" aria-label="لم يُسجَّل بعد" />
            ) : (
              <span className="slot__mark">
                <span
                  className={`${r.kind === "stamped" ? `stamp stamp--${r.action === "check_in" ? "in" : "out"}` : "pencil"}${r.key === freshId ? " is-fresh" : ""}`}
                  dir="ltr"
                >
                  {formatTime(r.time!, timeZone)}
                </span>
                {r.kind === "pencil" && <span className="slot__note"><Icon name="phone" />لم يُرسل بعد</span>}
                {r.kind === "stamped" && r.byAdmin && <span className="slot__note">أضافه المدير</span>}
                {r.kind === "stamped" && r.needsReview && (
                  <span className="slot__note slot__note--review"><Icon name="alert" />{noCheckIn(rows, i) ? "بدون حضور مسجّل" : STATUS_TEXT[r.event!.location_status] ?? "للمراجعة"}</span>
                )}
              </span>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
}
