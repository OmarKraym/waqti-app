import { formatDate, formatTime } from "../../lib/attendance";
import { formatDuration, type DayRow } from "../../lib/timecard";

/** The last work days: first check-in, last check-out, time worked. */
export function EarlierDays({ days, timeZone }: { days: DayRow[]; timeZone: string }) {
  if (days.length === 0) return null;
  return (
    <section className="earlier" aria-labelledby="earlier-title">
      <h3 id="earlier-title" className="section__title">الأيام السابقة</h3>
      <div className="group">
      <table className="days">
        <thead>
          <tr>
            <th scope="col">اليوم</th>
            <th scope="col">حضور</th>
            <th scope="col">انصراف</th>
            <th scope="col">المدة</th>
          </tr>
        </thead>
        <tbody>
          {days.map((d) => (
            <tr key={d.day}>
              <th scope="row">
                {formatDate(`${d.day}T12:00:00Z`, timeZone)}
                {d.needsReview && <span className="days__flag">للمراجعة</span>}
                {d.byAdmin && <span className="days__flag days__flag--by-admin">أضافه المدير</span>}
              </th>
              <td dir="ltr">{d.firstIn ? formatTime(d.firstIn, timeZone) : "—"}</td>
              <td dir="ltr">{d.lastOut ? formatTime(d.lastOut, timeZone) : "—"}</td>
              <td>{d.minutes > 0 ? formatDuration(d.minutes) : d.open ? "بدون انصراف" : "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>
    </section>
  );
}
