import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { format12, from12, to12, wheelIndex, type Period } from "../lib/time12";
import { Modal } from "./ui";

const ROW = 44; // keep in step with --wheel-row in styles.css
const HOURS = Array.from({ length: 12 }, (_, i) => String(i + 1));
const PERIODS: Period[] = ["ص", "م"];

/** One column of the picker: scroll it (or tap a row, or use the arrow keys) and the row in the middle band is the choice. */
function Wheel({ label, items, index, onIndex }: {
  label: string;
  items: string[];
  index: number;
  onIndex: (i: number) => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const last = useRef(index);
  useLayoutEffect(() => {
    if (box.current) box.current.scrollTop = index * ROW; // first paint: already resting on the current value
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const go = (i: number) => {
    const n = Math.max(0, Math.min(items.length - 1, i));
    box.current?.scrollTo({ top: n * ROW, behavior: "smooth" });
  };
  return (
    <div
      className="wheel" role="listbox" aria-label={label} tabIndex={0} ref={box}
      aria-activedescendant={`${label}-${index}`}
      onScroll={(e) => {
        const i = wheelIndex(e.currentTarget.scrollTop, ROW, items.length);
        if (i !== last.current) { last.current = i; onIndex(i); }
      }}
      onKeyDown={(e) => {
        if (e.key === "ArrowDown") { e.preventDefault(); go(index + 1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); go(index - 1); }
      }}
    >
      {items.map((t, i) => (
        <div key={t} id={`${label}-${i}`} role="option" aria-selected={i === index} className={`wheel-row${i === index ? " on" : ""}`} onClick={() => go(i)}>
          {t}
        </div>
      ))}
    </div>
  );
}

function Picker({ title, value, step, onDone, onClose }: {
  title: string;
  value: string;
  step: 1 | 5;
  onDone: (hhmm: string) => void;
  onClose: () => void;
}) {
  const start = /^\d{2}:\d{2}$/.test(value) ? to12(Number(value.slice(0, 2)), Number(value.slice(3))) : { h: 9, mm: "00", period: "ص" as Period };
  const minutes: string[] = [];
  for (let m = 0; m < 60; m += step) minutes.push(String(m).padStart(2, "0"));
  if (!minutes.includes(start.mm)) minutes.push(start.mm), minutes.sort(); // a value set elsewhere (e.g. the time of a punch)

  const [h, setH] = useState(HOURS.indexOf(String(start.h)));
  const [m, setM] = useState(minutes.indexOf(start.mm));
  const [p, setP] = useState(PERIODS.indexOf(start.period));

  // Esc / tap outside are handled by Modal. Enter confirms.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Enter" && !(e.target instanceof HTMLButtonElement)) { e.preventDefault(); done(); } };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const done = () => onDone(from12(Number(HOURS[h]), minutes[m], PERIODS[p]));

  return (
    <Modal title={title} onClose={onClose} sheet>
      <div className="wheels" dir="ltr">
        <div className="wheel-band" aria-hidden="true" />
        <Wheel label={`${title}: الساعة`} items={HOURS} index={h} onIndex={setH} />
        <span className="wheel-colon" aria-hidden="true">:</span>
        <Wheel label={`${title}: الدقائق`} items={minutes} index={m} onIndex={setM} />
        <Wheel label={`${title}: صباحاً أو مساءً`} items={PERIODS} index={p} onIndex={setP} />
      </div>
      <div className="modal-actions">
        <button type="button" className="btn primary block" onClick={done}>تم</button>
        <button type="button" className="btn block" onClick={onClose}>إلغاء</button>
      </div>
    </Modal>
  );
}

/**
 * A time of day: one box that shows the time ("8:05 ص"); tapping it opens wheels for hour, minutes and ص / م.
 * The value is 24-hour "HH:MM" like a native time input ("" = not chosen yet), so the rest of the app does not change.
 * The phone's own time picker follows the phone's settings and cannot be told to show ص / م, which is why the app has its own.
 */
export function TimeField({ label, value, onChange, step = 5, disabled }: {
  label: string;
  value: string;
  onChange: (hhmm: string) => void;
  /** Minutes between choices: 5 or 1. */
  step?: 1 | 5;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const shown = /^\d{2}:\d{2}$/.test(value) ? format12(Number(value.slice(0, 2)), Number(value.slice(3))) : "";
  return (
    <div className="field time-field">
      <span id={`tf-${label}`}>{label}</span>
      <button type="button" className={`time-btn${shown ? "" : " unset"}`} aria-labelledby={`tf-${label}`} aria-haspopup="dialog"
              disabled={disabled} onClick={() => setOpen(true)}>
        <span dir="ltr">{shown || "اختر الوقت"}</span>
      </button>
      {open && (
        <Picker title={label} value={value} step={step} onClose={() => setOpen(false)}
                onDone={(v) => { setOpen(false); onChange(v); }} />
      )}
    </div>
  );
}
