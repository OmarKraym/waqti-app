import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import type { SessionUser } from "../lib/api";
import {
  actionLabel,
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
import type { AttendanceEvent, AttendanceState, LocationStatus } from "../lib/types";
import { useInstallPrompt, useIosInstallHint, useOnline } from "./hooks";

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
          <h2>تعذّر تحميل حالة الحضور</h2>
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

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <img src={`${import.meta.env.BASE_URL}icons/icon.svg`} alt="" width={28} height={28} />
          <span className="truncate">{data.company.name}</span>
        </div>
        <button className="btn ghost small" onClick={onSignOut}>خروج</button>
      </header>

      <main className="container">
        {!online && (
          <div className={`banner ${allowQueue ? "warning" : "error"}`} role="alert">
            {allowQueue
              ? "لا يوجد اتصال بالإنترنت. يمكنك التسجيل، وسيُحفظ على الجهاز ويُرسل تلقائيًا عند عودة الاتصال (خلال 24 ساعة). لا تغيّر ساعة الهاتف."
              : "لا يوجد اتصال بالإنترنت. تسجيل الحضور يحتاج اتصالًا."}
          </div>
        )}
        {fromCache !== null && (
          <p className="muted small cache-note">
            تعرض آخر حالة محفوظة على الجهاز ({formatTime(new Date(fromCache).toISOString(), data.company.timezone)}).
          </p>
        )}

        <section className="card hello">
          <div className="min-w-0">
            <p className="muted small">مرحبًا</p>
            <h2 className="truncate">{data.employee.full_name}</h2>
          </div>
          {data.employee.employee_number && <span className="chip" dir="ltr">#{data.employee.employee_number}</span>}
        </section>

        <ServerClock offsetMs={offsetMs} timeZone={data.company.timezone} />

        <section className="card punch-card">
          <p className="status-line">
            {data.open_session
              ? `حاضر منذ ${formatTime(data.open_session.started_at, data.company.timezone)}`
              : "لا يوجد حضور مسجّل الآن"}
            {waiting.length > 0 && " (لم يُرسل بعد)"}
          </p>

          {state.phase === "unconfirmed" ? (
            <div className="unconfirmed" role="alert">
              <p>{ERROR_TEXT.network}</p>
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
                      ? "اضغط مرة واحدة"
                      : "سيُحفظ على الجهاز"}
              </span>
            </button>
          )}

          <PolicyNote data={data} />
          {hint && working && <p className="hint">{hint}</p>}

          {state.phase === "ready" && state.notice && (
            <div className={`banner ${state.notice.kind}`} role="status">
              <span>{state.notice.text}</span>
              <button className="x" aria-label="إغلاق" onClick={() => dispatch({ type: "DISMISS_NOTICE" })}>×</button>
            </div>
          )}
          {syncNote && (
            <div className={`banner ${syncNote.kind} sync-note`} role="status">
              <span>{syncNote.text}</span>
              <button className="x" aria-label="إغلاق" onClick={() => setSyncNote(null)}>×</button>
            </div>
          )}
          {waiting.length > 0 && (
            <p className="queue-count" role="status">
              بانتظار الإرسال: {waiting.length} {online ? "— جارٍ الإرسال…" : ""}
            </p>
          )}
        </section>

        {failed.length > 0 && (
          <section className="card failed-card" role="alert">
            <h3 className="section-title">تسجيلات لم يقبلها الخادم</h3>
            <ul className="events">
              {failed.map((q) => (
                <li key={q.request_id} className="failed-item">
                  <span className={`dot ${q.action === "check_in" ? "in" : "out"}`} />
                  <span className="ev-action">{q.action === "check_in" ? "حضور" : "انصراف"}</span>
                  <span className="ev-date muted">{formatDate(q.offline_at, data.company.timezone)}</span>
                  <span className="ev-time" dir="ltr">{formatTime(q.offline_at, data.company.timezone)}</span>
                  <span className="failed-reason">{ERROR_TEXT[q.error_code ?? "unknown"]}</span>
                </li>
              ))}
            </ul>
            <p className="muted small">هذه التسجيلات لم تُحسب. تواصل مع إدارة شركتك لتصحيحها.</p>
            <button className="btn ghost block" onClick={dismissFailed}>فهمت، إخفاء</button>
          </section>
        )}

        <RecentEvents events={data.recent_events} timeZone={data.company.timezone} />

        {install && (
          <button className="btn ghost block" onClick={install}>تثبيت التطبيق على الجهاز</button>
        )}
        {iosHint && (
          <div className="banner install-hint" role="note">
            <span>لتثبيت التطبيق: اضغط زر المشاركة في Safari ثم «إضافة إلى الشاشة الرئيسية».</span>
            <button className="x" aria-label="إغلاق" onClick={dismissIosHint}>×</button>
          </div>
        )}
      </main>
    </div>
  );
}

/** Shows the server's time (phone clock + the last measured offset), not the phone's own time. */
function ServerClock({ offsetMs, timeZone }: { offsetMs: number; timeZone: string }) {
  const [now, setNow] = useState(() => Date.now() + offsetMs);
  useEffect(() => {
    setNow(Date.now() + offsetMs);
    const t = setInterval(() => setNow(Date.now() + offsetMs), 1000);
    return () => clearInterval(t);
  }, [offsetMs]);
  const iso = new Date(now).toISOString();
  return (
    <section className="card clock" aria-label="الوقت الحالي">
      <div className="clock-time">{formatTime(iso, timeZone)}</div>
      <div className="muted">{formatDate(iso, timeZone)}</div>
    </section>
  );
}

function PolicyNote({ data }: { data: AttendanceState }) {
  const text =
    data.location_policy === "geofence"
      ? data.outside_action === "reject"
        ? "يجب أن تكون داخل نطاق مكان العمل."
        : "سيتم التحقق من موقعك، والتسجيل خارج النطاق يُرسل للمراجعة."
      : data.location_policy === "record"
        ? "سيتم تسجيل موقعك مع العملية."
        : "لا يُطلب الموقع لهذا الحساب.";
  return <p className="policy muted small">📍 {text}</p>;
}

const STATUS_TEXT: Partial<Record<LocationStatus, string>> = {
  outside: "خارج النطاق",
  unavailable: "بدون موقع",
  inaccurate: "دقة ضعيفة",
};

function RecentEvents({ events, timeZone }: { events: AttendanceEvent[]; timeZone: string }) {
  return (
    <section className="card">
      <h3 className="section-title">آخر الحركات</h3>
      {events.length === 0 ? (
        <p className="muted pad-sm">لا توجد حركات بعد.</p>
      ) : (
        <ul className="events">
          {events.map((e) => (
            <li key={e.id}>
              <span className={`dot ${e.action === "check_in" ? "in" : "out"}`} />
              <span className="ev-action">{e.action === "check_in" ? "حضور" : "انصراف"}</span>
              <span className="ev-date muted">{formatDate(e.server_time, timeZone)}</span>
              <span className="ev-time" dir="ltr">{formatTime(e.server_time, timeZone)}</span>
              {isQueuedEvent(e) ? (
                <span className="chip queued">بانتظار الإرسال</span>
              ) : (
                e.needs_review && <span className="chip warn">{STATUS_TEXT[e.location_status] ?? "مراجعة"}</span>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
