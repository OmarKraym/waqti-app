import { statusHeadline } from "../../lib/statusHeadline";
import type { CardRow } from "../../lib/timecard";
import type { AttendanceState } from "../../lib/types";
import { ServerClock } from "./ServerClock";

/** The dial card: who, the server clock, today's status in one line. */
export function StatusCard({ data, rows, offsetMs, nowMs }: { data: AttendanceState; rows: CardRow[]; offsetMs: number; nowMs: number }) {
  const tz = data.company.timezone;
  return (
    <section className={`status${data.open_session ? " status--present" : ""}`}>
      <p className="status__who">
        <span className="u-truncate">{data.employee.full_name}</span>
        {data.employee.employee_number && <span className="status__number" dir="ltr">{data.employee.employee_number}</span>}
      </p>
      <ServerClock offsetMs={offsetMs} timeZone={tz} rows={rows} openStart={data.open_session?.started_at ?? null} />
      <h2 className="status__head" aria-live="polite">
        <span className="status__dot" aria-hidden="true" />
        {statusHeadline(data, rows, nowMs, tz)}
      </h2>
      {data.leave_today && !rows.some((r) => r.kind !== "empty") && (
        <p className="status__note">لا يُطلب منك البصم اليوم. وإن سجّلت حضورك يُلغى هذا اليوم من إجازتك.</p>
      )}
    </section>
  );
}
