import { useState } from "react";
import { from12, to12, type Period } from "../lib/time12";

const HOURS = Array.from({ length: 12 }, (_, i) => i + 1);

/**
 * A time of day in 12-hour form (hour, minutes, ص / م). The value is 24-hour "HH:MM" like a native time input
 * ("" = not chosen yet), so the rest of the app does not change. The phone's own time picker follows the phone's
 * settings and cannot be told to show ص / م, which is why the app has its own.
 */
export function TimeField({ label, value, onChange, step = 5, disabled }: {
  label: string;
  value: string;
  onChange: (hhmm: string) => void;
  /** Minutes between choices: 5 or 1. */
  step?: 1 | 5;
  disabled?: boolean;
}) {
  // What to use for the other two parts while no hour is chosen yet.
  const [fallback, setFallback] = useState<{ mm: string; period: Period }>({ mm: "00", period: "ص" });
  const parsed = /^\d{2}:\d{2}$/.test(value) ? to12(Number(value.slice(0, 2)), Number(value.slice(3))) : null;
  const hour = parsed ? String(parsed.h) : "";
  const mm = parsed ? parsed.mm : fallback.mm;
  const period = parsed ? parsed.period : fallback.period;

  const minutes: string[] = [];
  for (let m = 0; m < 60; m += step) minutes.push(String(m).padStart(2, "0"));
  if (!minutes.includes(mm)) minutes.push(mm), minutes.sort(); // a value set elsewhere (e.g. the time of a punch)

  return (
    <div className="field time-field" role="group" aria-label={label}>
      <span aria-hidden="true">{label}</span>
      <div className="time-row" dir="ltr">
        <select aria-label={`${label}: الساعة`} value={hour} disabled={disabled}
                onChange={(e) => onChange(e.target.value === "" ? "" : from12(Number(e.target.value), mm, period))}>
          <option value="">--</option>
          {HOURS.map((h) => <option key={h} value={h}>{h}</option>)}
        </select>
        <span className="time-colon" aria-hidden="true">:</span>
        <select aria-label={`${label}: الدقائق`} value={mm} disabled={disabled}
                onChange={(e) => {
                  if (!parsed) return setFallback((f) => ({ ...f, mm: e.target.value }));
                  onChange(from12(parsed.h, e.target.value, period));
                }}>
          {minutes.map((m) => <option key={m} value={m}>{m}</option>)}
        </select>
        <select aria-label={`${label}: صباحاً أو مساءً`} value={period} disabled={disabled}
                onChange={(e) => {
                  const p = e.target.value as Period;
                  if (!parsed) return setFallback((f) => ({ ...f, period: p }));
                  onChange(from12(parsed.h, mm, p));
                }}>
          <option value="ص">ص</option>
          <option value="م">م</option>
        </select>
      </div>
    </div>
  );
}
