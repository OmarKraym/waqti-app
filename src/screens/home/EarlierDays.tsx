import { formatTime } from "../../lib/attendance";
import { dayLabel, formatDuration, type DayRow } from "../../lib/timecard";

/** The badge of a past day: what matters most first (review, then a missing check-out, then the time worked). */
function badge(d: DayRow): { tone: "success" | "warning" | "neutral"; text: string } {
  if (d.needsReview) return { tone: "warning", text: "للمراجعة" };
  if (d.open) return { tone: "warning", text: "بدون انصراف" };
  if (d.minutes > 0) return { tone: "success", text: formatDuration(d.minutes) };
  return { tone: "neutral", text: "—" };
}

/** The log of the last days the server sent: day, first check-in – last check-out, and a badge. */
export function EarlierDays({ days, timeZone }: { days: DayRow[]; timeZone: string }) {
  if (days.length === 0) return null;
  return (
    <section className="log" aria-labelledby="log-title">
      <div className="log__head">
        <h2 id="log-title" className="card__title">سجل الأيام السابقة</h2>
        <span className="log__sub">آخر {days.length === 1 ? "يوم" : `${days.length} أيام`} مسجّلة</span>
      </div>
      <ul className="log__list">
        {days.map((d) => {
          const l = dayLabel(d.day, timeZone);
          const b = badge(d);
          return (
            <li key={d.day} className="log__row">
              <div className="log__day">
                <span className="log__weekday">{l.weekday}</span>
                <span className="log__date" dir="ltr">{l.date}</span>
                {d.byAdmin && <span className="log__by-admin">أضافه المدير</span>}
              </div>
              <div className="log__end">
                {/* Each time is isolated (it ends in ص / م); the range reads in Arabic order: check-in, then check-out. */}
                <span className="log__times">
                  <bdi>{d.firstIn ? formatTime(d.firstIn, timeZone) : "--:--"}</bdi>
                  <span className="log__dash" aria-hidden="true"> - </span>
                  <bdi>{d.lastOut ? formatTime(d.lastOut, timeZone) : "--:--"}</bdi>
                </span>
                <span className={`pill pill--${b.tone}`}>{b.text}</span>
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
