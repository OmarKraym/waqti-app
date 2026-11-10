import { useEffect, useState } from "react";
import { formatClock, formatDate } from "../../lib/attendance";
import { clockParts } from "../../lib/time12";
import { formatDuration, workedToday, type CardRow } from "../../lib/timecard";

/** The server's time (phone clock + the last measured offset), not the phone's own time. */
export function ServerClock({ offsetMs, timeZone, rows, openStart }: {
  offsetMs: number; timeZone: string; rows: CardRow[]; openStart: string | null;
}) {
  const [now, setNow] = useState(() => Date.now() + offsetMs);
  useEffect(() => {
    // Tick on each new SERVER second (not every 1000 ms from an arbitrary start), so the
    // seconds never skip or stall.
    let t: ReturnType<typeof setTimeout>;
    const tick = () => {
      const server = Date.now() + offsetMs;
      setNow(server);
      t = setTimeout(tick, 1000 - (((server % 1000) + 1000) % 1000) + 5);
    };
    tick();
    return () => clearTimeout(t);
  }, [offsetMs]);
  const iso = new Date(now).toISOString();
  const c = clockParts(iso, timeZone);
  const worked = workedToday(rows, openStart, now);
  return (
    <div className="clock">
      <p className="clock__time">
        <span className="u-sr-only">الساعة الآن {formatClock(iso, timeZone)}</span>
        <span dir="ltr" aria-hidden="true">
          <span className="clock__hm">{c.hm}</span>
          <span className="clock__s">:{c.ss}</span>
          <span className="clock__ap">{c.period}</span>
        </span>
      </p>
      <p className="clock__date">{formatDate(iso, timeZone)}</p>
      {worked > 0 && (
        <p className="status__worked">مدة العمل اليوم <span>{formatDuration(worked)}</span></p>
      )}
    </div>
  );
}
