import { useEffect, useState } from "react";
import { api } from "../../lib/client";
import { AppError, ERROR_TEXT } from "../../lib/errors";
import { checkRange, defaultRange, historySummary, queryWindow } from "../../lib/history";
import { dayKey, earlierDays, type DayRow } from "../../lib/timecard";
import { Button, Icon, Modal } from "../../components";
import { LogList } from "./EarlierDays";

/** One quiet row on Home: opens the attendance log of a period the employee picks. */
export function HistoryButton({ onOpen }: { onOpen: () => void }) {
  return (
    <button type="button" className="card history-btn" onClick={onOpen} aria-haspopup="dialog">
      <span className="history-btn__icon" aria-hidden="true"><Icon name="calendar" /></span>
      <span className="history-btn__text">
        <span className="history-btn__title">سجل الدوام</span>
        <span className="history-btn__sub">اختر فترة لعرض أيام حضورك وانصرافك</span>
      </span>
      <Icon name="chevron" className="history-btn__chevron" />
    </button>
  );
}

/** The window: two dates (from – to), then the days of that period with a line of totals. */
export function HistorySheet({ timeZone, online, onClose }: { timeZone: string; online: boolean; onClose: () => void }) {
  const today = dayKey(Date.now(), timeZone);
  const [range, setRange] = useState(() => defaultRange(today));
  const [days, setDays] = useState<DayRow[] | null>(null);
  const [state, setState] = useState<"idle" | "loading" | "error">("idle");
  const [error, setError] = useState<string | null>(null);
  const problem = checkRange(range.from, range.to, today);

  async function show() {
    if (problem || !online || state === "loading") return;
    setState("loading");
    setError(null);
    try {
      const w = queryWindow(range.from, range.to);
      const events = await api.getHistory(w.fromIso, w.toIso);
      // Only the chosen days, in the company's time zone (today has its own card on Home).
      const inRange = events.filter((e) => { const d = dayKey(e.server_time, timeZone); return d >= range.from && d <= range.to; });
      setDays(earlierDays(inRange, Date.now(), timeZone, 400));
      setState("idle");
    } catch (e) {
      const code = e instanceof AppError ? e.code : "unknown";
      if (code === "not_authenticated") return void api.signOut();
      setError(code === "network" ? "تعذّر الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى." : ERROR_TEXT[code]);
      setState("error");
    }
  }
  // The default period is shown at once.
  useEffect(() => { void show(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <Modal title="سجل الدوام" onClose={onClose} sheet className="modal--tall">
      <form className="history-form" onSubmit={(e) => { e.preventDefault(); void show(); }}>
        <div className="two">
          <label className="field">
            <span>من</span>
            <input type="date" value={range.from} max={today} onChange={(e) => setRange((r) => ({ ...r, from: e.target.value }))} />
          </label>
          <label className="field">
            <span>إلى</span>
            <input type="date" value={range.to} max={today} onChange={(e) => setRange((r) => ({ ...r, to: e.target.value }))} />
          </label>
        </div>
        {problem && <p className="form__error" role="alert">{problem}</p>}
        {!online && <p className="form__error" role="alert">عرض السجل يحتاج اتصالًا بالإنترنت.</p>}
        <Button type="submit" variant="primary" block disabled={!!problem || !online} aria-busy={state === "loading"}>
          {/* not disabled while loading: the focus stays in the window (Esc still closes it) */}
          {state === "loading" ? "جارٍ التحميل…" : "عرض"}
        </Button>
      </form>
      <div className="history-result" aria-live="polite">
        {state === "error" && error && <p className="form__error" role="alert">{error}</p>}
        {state === "loading" && !days && <div className="center-block"><div className="spinner" /></div>}
        {days && (
          <>
            <p className="history-result__sum">{historySummary(days)}</p>
            {days.length > 0 && <LogList days={days} timeZone={timeZone} />}
          </>
        )}
      </div>
      <div className="modal__actions">
        <Button variant="quiet" block onClick={onClose}>إغلاق</Button>
      </div>
    </Modal>
  );
}
