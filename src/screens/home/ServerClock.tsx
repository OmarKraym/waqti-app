import { useEffect, useState } from "react";
import { formatClock, formatDate } from "../../lib/attendance";
import { clockParts } from "../../lib/time12";

/** The server's time now (phone clock + the last measured offset), re-rendered on each new SERVER second. */
export function useServerNow(offsetMs: number): number {
  const [now, setNow] = useState(() => Date.now() + offsetMs);
  useEffect(() => {
    // Tick on each new SERVER second (not every 1000 ms from an arbitrary start), so the seconds never skip or stall.
    let t: ReturnType<typeof setTimeout>;
    const tick = () => {
      const server = Date.now() + offsetMs;
      setNow(server);
      t = setTimeout(tick, 1000 - (((server % 1000) + 1000) % 1000) + 5);
    };
    tick();
    return () => clearTimeout(t);
  }, [offsetMs]);
  return now;
}

/** Today's date over the live server clock (12-hour, with ص / م), as on the design's hero card. */
export function ServerClock({ offsetMs, timeZone }: { offsetMs: number; timeZone: string }) {
  const now = useServerNow(offsetMs);
  const iso = new Date(now).toISOString();
  const c = clockParts(iso, timeZone);
  return (
    <div className="clock">
      <p className="clock__date">{formatDate(iso, timeZone)}</p>
      <p className="clock__time">
        <span className="u-sr-only">الساعة الآن {formatClock(iso, timeZone)}</span>
        <time dir="ltr" aria-hidden="true">
          <span className="clock__hm">{c.hm}</span>
          <span className="clock__s">:{c.ss}</span>
          <span className="clock__ap">{c.period}</span>
        </time>
      </p>
    </div>
  );
}
