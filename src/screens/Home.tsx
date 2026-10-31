import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import type { SessionUser } from "../lib/api";
import {
  actionLabel,
  formatClock,
  formatDate,
  formatTime,
  initialState,
  newRequestId,
  reduce,
  type Pending,
} from "../lib/attendance";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { readingHint, readLocation } from "../lib/location";
import {
  anchorFromCache,
  anchorFromServer,
  anchorOffsetMs,
  browserStorage,
  failedOf,
  isQueuedEvent,
  loadCachedState,
  loadQueue,
  makeQueuedPunch,
  pendingOf,
  saveCachedState,
  saveQueue,
  syncQueue,
  withQueue,
  type QueuedPunch,
  type TimeAnchor,
} from "../lib/offlineQueue";
import { dayKey, earlierDays, formatDuration, todayRows, type CardRow, type DayRow } from "../lib/timecard";
import type { AttendanceState, LocationStatus } from "../lib/types";
import { useInstallPrompt, useIosInstallHint, useOnline } from "./hooks";
import { AppBar, Banner, Icon } from "./ui";

const SYNC_EVERY_MS = 30_000;

export function Home({ user }: { user: SessionUser }) {
  const [state, dispatch] = useReducer(reduce, initialState);
  const busy = useRef(false); // blocks a second tap while one is being processed
  const online = useOnline();
  const install = useInstallPrompt();
  const [iosHint, dismissIosHint] = useIosInstallHint();
  const [hint, setHint] = useState<string | null>(null);

  // ---- offline support
  const storage = useMemo(() => browserStorage(), []);
  const [queue, setQueueState] = useState<QueuedPunch[]>(() => loadQueue(storage, user.id));
  const queueRef = useRef(queue);
  const setQueue = useCallback(
    (next: QueuedPunch[]): boolean => {
      const saved = saveQueue(storage, user.id, next);
      queueRef.current = next;
      setQueueState(next);
      return saved;
    },
    [storage, user.id],
  );
  // Latest signed server time (needed to prove the time of an offline punch).
  const anchor = useRef<TimeAnchor | null>(null);
  const [offsetMs, setOffsetMs] = useState(0);
  const setAnchor = useCallback((a: TimeAnchor) => {
    anchor.current = a;
    setOffsetMs(anchorOffsetMs(a));
  }, []);
  const [fromCache, setFromCache] = useState<number | null>(null); // time of the cached copy, or null when live
  const [syncNote, setSyncNote] = useState<{ kind: "success" | "error"; text: string } | null>(null);
  // The event just confirmed by the server: its stamp "lands" once (the only animation).
  const [freshId, setFreshId] = useState<string | null>(null);
  const syncing = useRef(false);

  const load = useCallback(async () => {
    dispatch({ type: "LOAD_START" });
    try {
      const data = await api.getAttendanceState();
      setAnchor(anchorFromServer(data.time_token, data.server_time));
      saveCachedState(storage, user.id, { data, saved_at_ms: Date.now() });
      setFromCache(null);
      dispatch({ type: "LOAD_OK", data });
    } catch (e) {
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      if (err.code === "not_authenticated") return void api.signOut();
      // Already showing live data in this session: keep it (and its monotonic anchor).
      if (err.code === "network" && anchor.current) return void dispatch({ type: "LOAD_FAIL", error: err });
      const cached = err.code === "network" ? loadCachedState(storage, user.id) : null;
      if (cached) {
        // App opened with no internet: show the last state saved on this phone (punches can be saved).
        setAnchor(anchorFromCache(cached));
        setFromCache(cached.saved_at_ms);
        dispatch({ type: "LOAD_OK", data: cached.data });
        return;
      }
      dispatch({ type: "LOAD_FAIL", error: err });
    }
  }, [storage, user.id, setAnchor]);

  /** Sends the punches saved on the phone, in order. Safe to call any time (one run at a time). */
  const sync = useCallback(async () => {
    if (syncing.current || pendingOf(queueRef.current).length === 0 || !navigator.onLine) return;
    syncing.current = true;
    try {
      const r = await syncQueue(queueRef.current, (input) => api.punchOffline(input));
      setQueue(r.queue);
      if (r.sent.length > 0) setFreshId(r.sent[r.sent.length - 1].event_id);
      // The "saved on this phone" notice is out of date once the server has answered.
      if (r.sent.length > 0 || r.refused.length > 0) dispatch({ type: "DISMISS_NOTICE" });
      if (r.refused.length > 0) {
        setSyncNote({ kind: "error", text: `لم يقبل الخادم ${r.refused.length} من التسجيلات المحفوظة على الجهاز. التفاصيل بالأسفل.` });
      } else if (r.sent.length > 0) {
        setSyncNote({ kind: "success", text: `تم إرسال ${r.sent.length} من التسجيلات المحفوظة على الجهاز وقبولها.` });
      }
    } catch (e) {
      if (e instanceof AppError && e.code === "not_authenticated") await api.signOut(); // the queue stays saved
    } finally {
      syncing.current = false;
    }
  }, [setQueue]);

  const refresh = useCallback(async () => {
    await sync();
    await load();
  }, [sync, load]);
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;

  useEffect(() => {
    refresh();
    // Coming back to the app or getting the connection back: send what is waiting, then reload.
    const onVisible = () => document.visibilityState === "visible" && refresh();
    const onOnline = () => refresh();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", onOnline);
    const timer = setInterval(() => {
      if (pendingOf(queueRef.current).length > 0) refresh();
    }, SYNC_EVERY_MS);
    return () => {
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", onOnline);
      clearInterval(timer);
    };
  }, [refresh]);

  /** Saves the punch on the phone. Returns false if the phone refused to save it. */
  function enqueue(pending: Pending, tapTime: number, tapPerf: number): boolean {
    if (!anchor.current) return false;
    const item = makeQueuedPunch(
      pending.request_id,
      pending.action,
      pending.reading ?? { kind: "not_requested" },
      anchor.current,
      tapTime,
      tapPerf,
    );
    const saved = setQueue([...queueRef.current, item]);
    if (saved) {
      dispatch({ type: "QUEUED", at: item.offline_at });
      // Still online (only the reply was lost): try again in a few seconds instead of waiting.
      if (navigator.onLine) setTimeout(() => refreshRef.current(), 3000);
    }
    return saved;
  }

  const submit = useCallback(
    async (pending: Pending, allowQueue: boolean, tapTime: number, tapPerf: number) => {
      try {
        const result = await api.punch({
          request_id: pending.request_id,
          expected_action: pending.action,
          reading: pending.reading ?? { kind: "not_requested" },
        });
        if (result.time_token) setAnchor(anchorFromServer(result.time_token, result.server_time));
        setFreshId(result.event_id);
        dispatch({ type: "PUNCH_OK", result });
        load(); // confirm the new state from the server
      } catch (e) {
        const err = e instanceof AppError ? e : new AppError("unknown", String(e));
        if (err.code === "not_authenticated") return void api.signOut();
        // Reply lost: keep it on the phone with the SAME request_id. If the server already saved it,
        // sending it again just returns the saved punch.
        if (err.code === "network" && allowQueue && enqueue(pending, tapTime, tapPerf)) return;
        dispatch({ type: "PUNCH_FAIL", error: err });
        if (err.code === "state_changed") load();
      } finally {
        busy.current = false;
      }
    },
    [load, setAnchor], // enqueue only uses refs and stable setters
  );

  async function onTap(view: AttendanceState, allowQueue: boolean) {
    if (busy.current) return;
    busy.current = true;
    setHint(null);
    setSyncNote(null);
    // The time of the TAP (not of the GPS answer) is what is recorded offline.
    const tapTime = Date.now();
    const tapPerf = performance.now();
    const pending: Pending = { request_id: newRequestId(), action: view.next_action, reading: null };
    dispatch({ type: "TAP", request_id: pending.request_id, action: pending.action });
    const reading = await readLocation(view.location_policy);
    setHint(readingHint(reading, view.max_accuracy_m));
    dispatch({ type: "LOCATED", reading });
    const full = { ...pending, reading };

    // Older punches are still waiting: try to send them first, so the order stays right.
    if (navigator.onLine && pendingOf(queueRef.current).length > 0) await sync();

    if (allowQueue && (!navigator.onLine || pendingOf(queueRef.current).length > 0)) {
      if (!enqueue(full, tapTime, tapPerf)) dispatch({ type: "PUNCH_FAIL", error: new AppError("network") });
      busy.current = false;
      return;
    }
    await submit(full, allowQueue, tapTime, tapPerf);
  }

  async function onRetry(pending: Pending) {
    if (busy.current) return;
    busy.current = true;
    dispatch({ type: "RETRY" });
    await submit(pending, false, Date.now(), performance.now()); // same request_id: never recorded twice
  }

  function onSignOut() {
    const waiting = pendingOf(queueRef.current).length;
    if (
      waiting > 0 &&
      !window.confirm(`لديك ${waiting} تسجيل لم يُرسل بعد. سيبقى محفوظًا على هذا الجهاز ويُرسل عند دخولك مرة أخرى. هل تريد الخروج؟`)
    ) {
      return;
    }
    api.signOut();
  }

  function dismissFailed() {
    setQueue(pendingOf(queueRef.current));
    setSyncNote(null);
  }

  if (state.phase === "loading") {
    return (
      <div className="center-screen" aria-busy="true">
        <div className="spinner" />
        <p className="muted">جارٍ تحميل حالتك…</p>
      </div>
    );
  }

  if (state.phase === "load_error") {
    return (
      <main className="center-screen">
        <div className="card pad">
          <Icon name="alert" className="pad-icon" />
          <h2 className="pad-title">تعذّر تحميل حالة الحضور</h2>
          <p className="muted">
            {state.error.code === "network" ? "تحقق من اتصالك بالإنترنت." : ERROR_TEXT[state.error.code]}
          </p>
          <div className="row">
            <button className="btn primary" onClick={refresh}>إعادة المحاولة</button>
            <button className="btn ghost" onClick={onSignOut}>تسجيل الخروج</button>
          </div>
        </div>
      </main>
    );
  }

  const data = withQueue(state.data, queue);
  // Offline punches need storage on the phone and a signed server time to prove the time later.
  const allowQueue = storage !== null && anchor.current !== null;
  const waiting = pendingOf(queue);
  const failed = failedOf(queue);
  const working = state.phase === "locating" || state.phase === "submitting";
  const action = state.phase === "ready" ? data.next_action : state.pending.action;
  const canTap = !working && (online || allowQueue);
  const tz = data.company.timezone;
  const nowMs = Date.now() + offsetMs;
  const rows = todayRows(data.recent_events, data.open_session?.started_at ?? null, nowMs, tz);
  const days = earlierDays(data.recent_events.filter((e) => !isQueuedEvent(e)), nowMs, tz);

  return (
    <div className="app">
      <AppBar
        className="brand-bar"
        lead={<img className="brand-mark" src={`${import.meta.env.BASE_URL}icons/icon.svg`} alt="" width={32} height={32} />}
        title={data.company.name}
        action={<button className="btn quiet small" onClick={onSignOut}><Icon name="signOut" />خروج</button>}
      />

      <main className="container">
        {!online && (
          <Banner kind={allowQueue ? "warning" : "error"}>
            {allowQueue
              ? "لا يوجد اتصال بالإنترنت. يمكنك التسجيل وسيُحفظ على الجهاز. افتح التطبيق مع الإنترنت خلال 3 أيام ليُعتمد، ولا تغيّر ساعة الهاتف ولا تحذف التطبيق."
              : "لا يوجد اتصال بالإنترنت. تسجيل الحضور يحتاج اتصالًا."}
          </Banner>
        )}

        <section className="status" aria-live="polite">
          <p className="who">
            <span className="truncate">{data.employee.full_name}</span>
            {data.employee.employee_number && <span className="who-number" dir="ltr">{data.employee.employee_number}</span>}
          </p>
          <h2 className="status-head">{statusHeadline(data, rows, nowMs, tz)}</h2>
          <ServerClock offsetMs={offsetMs} timeZone={tz} />
          {fromCache !== null && (
            <p className="cache-note">
              تعرض آخر حالة محفوظة على الجهاز ({formatTime(new Date(fromCache).toISOString(), tz)}).
            </p>
          )}
        </section>

        <section className="timecard" aria-label="بطاقة اليوم">
          <h3 className="timecard-day">{formatDate(new Date(nowMs).toISOString(), tz)}</h3>
          <ol className="slots">
            {rows.map((r) => (
              <li key={r.key} className={`slot ${r.action === "check_in" ? "in" : "out"}`}>
                <span className="slot-label">{r.action === "check_in" ? "حضور" : "انصراف"}</span>
                {r.kind === "empty" ? (
                  <span className="slot-empty" role="img" aria-label="لم يُسجَّل بعد" />
                ) : (
                  <span className="slot-mark">
                    <span
                      className={`${r.kind === "stamped" ? "stamp" : "pencil"} ${r.action === "check_in" ? "in" : "out"}${r.key === freshId ? " fresh" : ""}`}
                      dir="ltr"
                    >
                      {formatTime(r.time!, tz)}
                    </span>
                    {r.kind === "pencil" && <span className="slot-note"><Icon name="phone" />لم يُرسل بعد</span>}
                    {r.kind === "stamped" && (r.needsReview ? (
                      <span className="slot-note review"><Icon name="alert" />{STATUS_TEXT[r.event!.location_status] ?? "للمراجعة"}</span>
                    ) : (
                      <span className="slot-note ok"><Icon name="check" />مؤكَّد</span>
                    ))}
                  </span>
                )}
              </li>
            ))}
          </ol>
        </section>

        {state.phase === "unconfirmed" ? (
          <div className="unconfirmed" role="alert">
            <p><Icon name="alert" className="inline-icon" />{ERROR_TEXT.network}</p>
            <div className="row">
              <button className="btn primary" onClick={() => onRetry(state.pending)}>إعادة المحاولة</button>
              <button className="btn ghost" onClick={refresh}>تحديث الحالة</button>
            </div>
          </div>
        ) : (
          <button
            className={`punch ${action === "check_in" ? "in" : "out"}`}
            onClick={() => onTap(data, allowQueue)}
            disabled={!canTap /* a stale tap is still safe: the server checks expected_action */}
            aria-busy={working}
          >
            <span className="punch-label">{actionLabel(action)}</span>
            <span className="punch-sub">
              {state.phase === "locating"
                ? "جارٍ تحديد الموقع…"
                : state.phase === "submitting"
                  ? "جارٍ الإرسال للخادم…"
                  : online
                    ? null
                    : "سيُحفظ على الجهاز"}
            </span>
          </button>
        )}

        <PolicyNote data={data} />
        {hint && working && <p className="hint">{hint}</p>}

        {state.phase === "ready" && state.notice && (
          <Banner kind={state.notice.kind} onClose={() => dispatch({ type: "DISMISS_NOTICE" })}>{state.notice.text}</Banner>
        )}
        {syncNote && (
          <Banner kind={syncNote.kind} className="sync-note" onClose={() => setSyncNote(null)}>{syncNote.text}</Banner>
        )}
        {waiting.length > 0 && (
          <p className="queue-count" role="status">
            <Icon name="phone" className="inline-icon" />
            بانتظار الإرسال: {waiting.length} {online ? "— جارٍ الإرسال…" : ""}
          </p>
        )}

        {failed.length > 0 && (
          <section className="failed-card" role="alert">
            <h3 className="section-title"><Icon name="alert" className="inline-icon" />تسجيلات لم يقبلها الخادم</h3>
            <ul className="failed-list">
              {failed.map((q) => (
                <li key={q.request_id} className="failed-item">
                  <span className="failed-what">
                    {q.action === "check_in" ? "حضور" : "انصراف"} {formatDate(q.offline_at, tz)}{" "}
                    <span dir="ltr">{formatTime(q.offline_at, tz)}</span>
                  </span>
                  <span className="failed-reason">{ERROR_TEXT[q.error_code ?? "unknown"]}</span>
                </li>
              ))}
            </ul>
            <p className="hint-line">هذه التسجيلات لم تُحسب. تواصل مع إدارة شركتك لتصحيحها.</p>
            <button className="btn ghost block" onClick={dismissFailed}>فهمت، إخفاء</button>
          </section>
        )}

        <EarlierDays days={days} timeZone={tz} />

        {install && (
          <button className="btn ghost block" onClick={install}>تثبيت التطبيق على الجهاز</button>
        )}
        {iosHint && (
          <div className="banner install-hint" role="note">
            <span className="banner-text">لتثبيت التطبيق: اضغط زر المشاركة في Safari ثم «إضافة إلى الشاشة الرئيسية».</span>
            <button className="x" aria-label="إغلاق" onClick={dismissIosHint}><Icon name="close" /></button>
          </div>
        )}
      </main>
    </div>
  );
}

function statusHeadline(data: AttendanceState, rows: CardRow[], nowMs: number, tz: string): string {
  // Nothing counts until the server stamps it: a pencil entry never reads as done.
  const last = [...rows].reverse().find((r) => r.kind !== "empty");
  if (last?.kind === "pencil") {
    return last.action === "check_in" ? "حضورك لم يُرسل بعد" : "انصرافك لم يُرسل بعد";
  }
  if (data.open_session) {
    const start = data.open_session.started_at;
    const sameDay = dayKey(start, tz) === dayKey(nowMs, tz);
    return `أنت حاضر منذ ${sameDay ? "" : "أمس "}${formatTime(start, tz)}`;
  }
  const lastOut = [...rows].reverse().find((r) => r.action === "check_out" && r.time);
  if (lastOut?.time) return `سجّلت انصرافك الساعة ${formatTime(lastOut.time, tz)}`;
  return "لم تسجّل حضورك اليوم";
}

/** The server's time (phone clock + the last measured offset), not the phone's own time. */
function ServerClock({ offsetMs, timeZone }: { offsetMs: number; timeZone: string }) {
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
  return (
    <p className="clock-line">
      الساعة الآن <span dir="ltr">{formatClock(new Date(now).toISOString(), timeZone)}</span>
    </p>
  );
}

function PolicyNote({ data }: { data: AttendanceState }) {
  const text =
    data.location_policy === "geofence"
      ? data.outside_action === "reject"
        ? "يجب أن تكون داخل نطاق مكان العمل."
        : "يُتحقق من موقعك، والتسجيل خارج النطاق يُرسل للمراجعة."
      : data.location_policy === "record"
        ? "يُسجَّل موقعك مع كل عملية."
        : "لا يُطلب الموقع لهذا الحساب.";
  return <p className="policy"><Icon name="pin" className="inline-icon" />{text}</p>;
}

const STATUS_TEXT: Partial<Record<LocationStatus, string>> = {
  outside: "خارج النطاق",
  unavailable: "بدون موقع",
  inaccurate: "دقة ضعيفة",
};

function EarlierDays({ days, timeZone }: { days: DayRow[]; timeZone: string }) {
  if (days.length === 0) return null;
  return (
    <section className="earlier" aria-labelledby="earlier-title">
      <h3 id="earlier-title" className="section-title">الأيام السابقة</h3>
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
                {d.needsReview && <span className="day-flag">للمراجعة</span>}
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
