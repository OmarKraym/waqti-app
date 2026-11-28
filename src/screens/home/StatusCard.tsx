import type { AttendanceState } from "../../lib/types";
import { Icon } from "../../components";
import { ServerClock } from "./ServerClock";

/** The hero card: who he is (small, on top), then the date, the live server clock and today's shift (the larger part). */
export function StatusCard({ data, offsetMs, shift, job }: {
  data: AttendanceState; offsetMs: number;
  /** Today's hours from the schedule ("09:00 – 17:00", or the day-off label); null when the company does not show it. */
  shift: string | null;
  /** "Job title • department"; null when the company does not show it. */
  job: string | null;
}) {
  return (
    <section className="card hero" aria-label="ملخص اليوم والوقت الحالي">
      <div className="hero__who">
        <div className="u-min-w-0">
          <h1 className="hero__name u-truncate">{data.employee.full_name}</h1>
          {job && <p className="hero__job">{job}</p>}
        </div>
        {data.employee.employee_number && <span className="code" dir="ltr">{data.employee.employee_number}</span>}
      </div>
      <div className="hero__time">
        <ServerClock offsetMs={offsetMs} timeZone={data.company.timezone} />
        {shift && (
          <span className="tag" title="دوام اليوم">
            <Icon name="clock" />
            <span dir="ltr">{shift}</span>
          </span>
        )}
      </div>
    </section>
  );
}
