import { formatTime } from "../../lib/attendance";
import { statusHeadline } from "../../lib/statusHeadline";
import { clockDuration, todayEnds, workedToday, type CardRow } from "../../lib/timecard";
import type { AttendanceState, LocationStatus } from "../../lib/types";
import { Icon } from "../../components";
import { useServerNow } from "./ServerClock";

const STATUS_TEXT: Partial<Record<LocationStatus, string>> = {
  outside: "خارج النطاق",
  unavailable: "بدون موقع",
  inaccurate: "دقة ضعيفة",
};

/** A check-out with no check-in before it (the employee forgot to check in). */
function noCheckIn(rows: CardRow[], i: number): boolean {
  return rows[i].action === "check_out" && rows[i].kind === "stamped" && (i === 0 || rows[i - 1].action === "check_out");
}

/** The colour of the status badge: green while he is at work, amber while something waits, grey otherwise. */
function tone(data: AttendanceState, rows: CardRow[]): "success" | "warning" | "neutral" {
  const last = [...rows].reverse().find((r) => r.kind !== "empty");
  if (last?.kind === "pencil") return "warning";
  if (data.open_session) return "success";
  return "neutral";
}

/** One of the three cells: label over a time. A punch still on the phone is grey and dashed; the newest one flashes. */
function Cell({ label, kind, row, timeZone, freshId }: { label: string; kind: "in" | "out"; row?: CardRow; timeZone: string; freshId: string | null }) {
  return (
    <div className={`today__cell today__cell--${kind}`}>
      <span className="today__label">{label}</span>
      {row?.time ? (
        <span className={`today__time${row.kind === "pencil" ? " is-pencil" : ""}${row.key === freshId ? " is-fresh" : ""}`} dir="ltr">
          {formatTime(row.time, timeZone)}
        </span>
      ) : (
        <span className="today__time is-empty" dir="ltr" aria-label="لم يُسجَّل بعد">--:--</span>
      )}
    </div>
  );
}

/** Today's attendance card: status, check-in, check-out, hours; every punch listed when there is more to say. */
export function Timecard({ data, rows, offsetMs, freshId }: { data: AttendanceState; rows: CardRow[]; offsetMs: number; freshId: string | null }) {
  const tz = data.company.timezone;
  const now = useServerNow(offsetMs);
  const { firstIn, lastOut } = todayEnds(rows);
  const worked = workedToday(rows, data.open_session?.started_at ?? null, now);
  const filled = rows.filter((r) => r.kind !== "empty");
  const detail = filled.length > 2 || filled.some((r) => r.kind === "pencil" || r.byAdmin || r.needsReview);
  return (
    <section className="card today" aria-label="حضور اليوم">
      <header className="today__head">
        <h2 className="card__title">حضور اليوم</h2>
        <span className={`badge-status badge-status--${tone(data, rows)}`} role="status" aria-live="polite">
          <span className="badge-status__dot" aria-hidden="true" />
          {statusHeadline(data, rows, now, tz)}
        </span>
      </header>
      <div className="today__cells">
        <Cell label="وقت الحضور" kind="in" row={firstIn} timeZone={tz} freshId={freshId} />
        <Cell label="وقت الانصراف" kind="out" row={lastOut} timeZone={tz} freshId={freshId} />
        <div className="today__cell">
          <span className="today__label">إجمالي الساعات</span>
          <span className={`today__time${worked > 0 ? "" : " is-empty"}`} dir="ltr">{clockDuration(worked)}</span>
        </div>
      </div>
      {detail && (
        <ol className="today__list" aria-label="حركات اليوم">
          {rows.map((r, i) => r.kind === "empty" ? null : (
            <li key={r.key} className="today__item">
              <span className={`today__kind today__kind--${r.action === "check_in" ? "in" : "out"}`}>
                <Icon name={r.action === "check_in" ? "arrive" : "leave"} />
                {r.action === "check_in" ? "حضور" : "انصراف"}
              </span>
              <span className={`today__item-time today__item-time--${r.action === "check_in" ? "in" : "out"}`} dir="ltr">{formatTime(r.time!, tz)}</span>
              {r.kind === "pencil" && <span className="note-chip"><Icon name="phone" />لم يُرسل بعد</span>}
              {r.kind === "stamped" && r.byAdmin && <span className="note-chip">أضافه المدير</span>}
              {r.kind === "stamped" && r.needsReview && (
                <span className="note-chip note-chip--warning"><Icon name="alert" />{noCheckIn(rows, i) ? "بدون حضور مسجّل" : STATUS_TEXT[r.event!.location_status] ?? "للمراجعة"}</span>
              )}
            </li>
          ))}
        </ol>
      )}
      {data.leave_today && filled.length === 0 && (
        <p className="today__note">لا يُطلب منك البصم اليوم. وإن سجّلت حضورك يُلغى هذا اليوم من إجازتك.</p>
      )}
    </section>
  );
}
