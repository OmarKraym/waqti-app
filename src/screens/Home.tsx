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
import { gpsPrompt, readLocation } from "../lib/location";
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
import { biometricStep, fingerprintTicket, supportsPlatformAuthenticator } from "../lib/biometric";
import { nextBoundaryMs, windowText } from "../lib/punchWindow";
import { holidayBanner, holidayItems, loadCalendar, offLabel, saveCalendar, type Calendar } from "../lib/calendar";
import { dayKey, earlierDays, formatDuration, todayRows, workedToday, type CardRow, type DayRow } from "../lib/timecard";
import type { AttendanceAction, AttendanceState, LocationStatus, PunchResult, RequestType } from "../lib/types";
import { clockParts } from "../lib/time12";
import { useInstallPrompt, useOnline } from "./hooks";
import { DeviceSetup } from "./DeviceSetup";
import { ConfirmSignOut, type ProfileInfo } from "./Profile";
import { Banner, Icon, Modal } from "./ui";

const SYNC_EVERY_MS = 30_000;
const OFFLINE_PUNCHES = false;

export function Home({ user, onNewRequest, onOpenProfile, onInfo, onPunched }: {
  user: SessionUser;
  onNewRequest: (type: RequestType) => void;
  /** The app logo at the top opens the profile. */
  onOpenProfile: () => void;
  /** Who the employee is (shown on the profile screen). */
  onInfo: (info: ProfileInfo) => void;
  /** The server confirmed a punch made just now (not one loaded from history). */
  onPunched: (result: PunchResult) => void;
}) {
  const [state, dispatch] = useReducer(reduce, initialState);
  const busy = useRef(false); // blocks a second tap while one is being processed
  const online = useOnline();
  const install = useInstallPrompt();

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
  // Fingerprint (phase 8b): register this phone first / the check before a punch.
  const [setupNeeded, setSetupNeeded] = useState(false);
  const [bioBusy, setBioBusy] = useState(false);
  const [gpsNote, setGpsNote] = useState<string | null>(null);
  const [bioNote, setBioNote] = useState<{ kind: "success" | "warning" | "error"; text: string } | null>(null);
  const [confirmNoIn, setConfirmNoIn] = useState(false); // phase 13: confirm "check out without a check-in"
  const [confirmOut, setConfirmOut] = useState(false); // only used by the load-error screen (the profile has its own button)

  // Company calendar (phase 16e): today's official holiday and the name of the weekly day off. Saved on the phone.
  const [calendar, setCalendar] = useState<Calendar | null>(() => loadCalendar(user.id));
  useEffect(() => {
    if (!navigator.onLine) return;
    api.getCalendar().then((c) => { if (c) { saveCalendar(user.id, c); setCalendar(c); } }).catch(() => undefined);
  }, [user.id]);

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

  // ---- phase 8: fingerprint registration prompt and punch-window timer (need the server's state)
  const live = state.phase === "loading" || state.phase === "load_error" ? null : state.data;
  const bio = live?.biometric;
  useEffect(() => {
    if (live) onInfo({ employee: live.employee, company: live.company, biometric: live.biometric });
  }, [live?.employee.full_name, live?.employee.employee_number, live?.company.name, live?.biometric?.policy, live?.biometric?.has_device, live?.biometric?.login_enabled]); // eslint-disable-line react-hooks/exhaustive-deps
  const [unsupportedNote, setUnsupportedNote] = useState(false);
  useEffect(() => {
    if (!bio || bio.policy !== "required" || bio.has_device) {
      setUnsupportedNote(false);
      setSetupNeeded(false); // the company switched the fingerprint off (or the device got registered elsewhere)
      return;
    }
    let cancelled = false;
    supportsPlatformAuthenticator().then((can) => {
      if (cancelled) return;
      if (can) setSetupNeeded(true);
      else setUnsupportedNote(true);
    });
    return () => { cancelled = true; };
  }, [bio?.policy, bio?.has_device]); // eslint-disable-line react-hooks/exhaustive-deps

  const win = live?.punch_window;
  useEffect(() => {
    if (!win || win.allowed) return;
    // Ask the server again when the window opens (server clock), and every 5 minutes as a fallback.
    const nb = nextBoundaryMs(win, Date.now() + offsetMs);
    const t1 = nb === null ? undefined : setTimeout(() => refreshRef.current(), Math.min(nb + 1000, 6 * 3600 * 1000));
    const t2 = setInterval(() => refreshRef.current(), 5 * 60 * 1000);
    return () => { clearTimeout(t1); clearInterval(t2); };
  }, [win?.allowed, win?.opens_at, offsetMs]); // eslint-disable-line react-hooks/exhaustive-deps

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
          biometric: pending.biometric,
        });
        if (result.time_token) setAnchor(anchorFromServer(result.time_token, result.server_time));
        setFreshId(result.event_id);
        dispatch({ type: "PUNCH_OK", result });
        onPunched(result);
        load(); // confirm the new state from the server
      } catch (e) {
        const err = e instanceof AppError ? e : new AppError("unknown", String(e));
        if (err.code === "not_authenticated") return void api.signOut();
        // Reply lost: keep it on the phone with the SAME request_id. If the server already saved it,
        // sending it again just returns the saved punch.
        if (err.code === "network" && allowQueue && enqueue(pending, tapTime, tapPerf)) return;
        dispatch({ type: "PUNCH_FAIL", error: err });
        // The server's state moved on (other device, window closed, device removed): show the current one.
        if (["state_changed", "outside_punch_window", "day_off", "biometric_required", "device_not_registered"].includes(err.code)) load();
      } finally {
        busy.current = false;
      }
    },
    [load, setAnchor, onPunched], // enqueue only uses refs and stable setters
  );

  /** `override` = record a check-out although there is no check-in (phase 13). It is never queued: the server must stamp it. */
  async function onTap(view: AttendanceState, allowQueue: boolean, override?: AttendanceAction) {
    if (busy.current) return;
    busy.current = true;
    setSyncNote(null);
    setBioNote(null);
    setGpsNote(null);
    // GPS first: if the phone cannot give a position, ask the employee to switch it on before anything else
    // (no fingerprint, no server call). The reading is reused below for the punch.
    setBioBusy(true); // the button shows it is working while the phone looks for a position
    const earlyReading = await readLocation(view.location_policy).finally(() => setBioBusy(false));
    const prompt = gpsPrompt(earlyReading);
    if (prompt) {
      setGpsNote(prompt);
      busy.current = false;
      return;
    }
    // Fingerprint next (phase 8b). A cancelled prompt records nothing.
    const requestId = newRequestId();
    let biometric: "ticket" | "unsupported" = "ticket";
    try {
      setBioBusy(true);
      const step = await biometricStep(view.biometric ?? { policy: "off", has_device: false });
      if (step === "register") {
        setSetupNeeded(true);
        busy.current = false;
        return;
      }
      if (step === "unsupported") biometric = "unsupported";
      if (step === "fingerprint") await fingerprintTicket(api, requestId);
    } catch (e) {
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      if (err.code === "not_authenticated") return void api.signOut();
      setBioNote({ kind: "error", text: ERROR_TEXT[err.code] });
      busy.current = false;
      if (err.code === "device_not_registered" || err.code === "forbidden") load();
      return;
    } finally {
      setBioBusy(false);
    }
    // The time of the TAP (not of the GPS answer) is what is recorded offline.
    const tapTime = Date.now();
    const tapPerf = performance.now();
    const pending: Pending = { request_id: requestId, action: override ?? view.next_action, reading: null, biometric };
    dispatch({ type: "TAP", request_id: pending.request_id, action: pending.action });
    const reading = earlyReading;
    dispatch({ type: "LOCATED", reading });
    const full = { ...pending, reading };

    // Older punches are still waiting: try to send them first, so the order stays right.
    if (navigator.onLine && pendingOf(queueRef.current).length > 0) await sync();

    if (allowQueue && !override && !view.forgot_check_in && (!navigator.onLine || pendingOf(queueRef.current).length > 0)) {
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
            <button className="btn ghost" onClick={() => setConfirmOut(true)}>تسجيل الخروج</button>
          </div>
        </div>
        {confirmOut && <ConfirmSignOut user={user} onCancel={() => setConfirmOut(false)} />}
      </main>
    );
  }

  const data = withQueue(state.data, queue);
  // Offline punching is switched off (security audit SEC-001: the server cannot prove a phone's clock, so a
  // punch is only recorded while the server can stamp it). Punches saved on a phone before this change are
  // still sent once; the server refuses them and they are listed below for the company to correct.
  const allowQueue = OFFLINE_PUNCHES && storage !== null && anchor.current !== null;
  const waiting = pendingOf(queue);
  const failed = failedOf(queue);
  const working = state.phase === "locating" || state.phase === "submitting";
  const action = state.phase === "ready" ? data.next_action : state.pending.action;
  const forgot = !!data.forgot_check_in; // phase 14: the button is already "check out" (no check-in today)
  // Phase 8a: outside the allowed times the button is off (the server refuses anyway). Old cached states have no window.
  const blocked = !!data.punch_window && !data.punch_window.allowed && fromCache === null;
  const canTap = !working && !bioBusy && !blocked && (online || (allowQueue && !data.forgot_check_in));
  const tz = data.company.timezone;
  const nowMs = Date.now() + offsetMs;
  const rows = todayRows(data.recent_events, data.open_session?.started_at ?? null, nowMs, tz);
  const days = earlierDays(data.recent_events.filter((e) => !isQueuedEvent(e)), nowMs, tz);

  return (
    <div className="app">
      <header className="topbar">
        <button className="logo-btn" onClick={onOpenProfile} aria-label="حسابي">
          <img className="brand-mark" src={`${import.meta.env.BASE_URL}icons/icon.svg`} alt="" width={36} height={36} />
        </button>
        <h1 className="topbar-title truncate">{data.company.name}</h1>
        <span className="topbar-end" aria-hidden="true" />
      </header>

      <main className="container has-punch">
        {holidayBanner(calendar) && <Banner kind="success">{holidayBanner(calendar)}</Banner>}
        {!online && (
          <Banner kind={allowQueue ? "warning" : "error"}>
            {allowQueue
              ? "لا يوجد اتصال بالإنترنت. يمكنك التسجيل وسيُحفظ على الجهاز. افتح التطبيق مع الإنترنت خلال 3 أيام ليُعتمد، ولا تغيّر ساعة الهاتف ولا تحذف التطبيق."
              : "لا يوجد اتصال بالإنترنت. تسجيل الحضور يحتاج اتصالًا."}
          </Banner>
        )}

        <section className={`status${data.open_session ? " present" : ""}`}>
          <p className="who">
            <span className="truncate">{data.employee.full_name}</span>
            {data.employee.employee_number && <span className="who-number" dir="ltr">{data.employee.employee_number}</span>}
          </p>
          <ServerClock offsetMs={offsetMs} timeZone={tz} rows={rows} openStart={data.open_session?.started_at ?? null} />
          <h2 className="status-head" aria-live="polite">
            <span className="status-dot" aria-hidden="true" />
            {statusHeadline(data, rows, nowMs, tz)}
          </h2>
        </section>

        <section className="timecard" aria-label="بطاقة اليوم">
          <h3 className="timecard-day">سجل اليوم</h3>
          <ol className="slots">
            {rows.map((r, i) => (
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
                    {r.kind === "stamped" && r.needsReview && (
                      <span className="slot-note review"><Icon name="alert" />{noCheckIn(rows, i) ? "بدون حضور مسجّل" : STATUS_TEXT[r.event!.location_status] ?? "للمراجعة"}</span>
                    )}
                  </span>
                )}
              </li>
            ))}
          </ol>
        </section>

        {holidayItems(calendar, dayKey(nowMs, tz)).length > 0 && (
          <section className="holidays-card" aria-labelledby="holidays-title">
            <h3 id="holidays-title" className="holidays-title">العطل الرسمية</h3>
            <ul className="holidays-list">
              {holidayItems(calendar, dayKey(nowMs, tz)).map((h) => (
                <li key={`${h.name}-${h.when}`} className={h.cancelled ? "cancelled" : undefined}>
                  <span className="holiday-name">{h.name}</span>
                  <span className="holiday-when" dir="auto">{h.when}</span>
                  {h.note && <span className="holiday-note">{h.note}</span>}
                </li>
              ))}
            </ul>
          </section>
        )}

        {setupNeeded ? (
          <DeviceSetup
            onDone={() => {
              setSetupNeeded(false);
              setBioNote({ kind: "success", text: "تم تسجيل البصمة لهذا الجهاز. يمكنك الآن تسجيل الحضور." });
              load();
            }}
          />
        ) : state.phase === "unconfirmed" ? (
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
            <span className="punch-icon" aria-hidden="true">
              <Icon name={data.biometric?.policy === "required" ? "fingerprint" : action === "check_in" ? "arrive" : "leave"} />
            </span>
            <span className="punch-text">
            <span className="punch-label">{actionLabel(action)}</span>
            <span className="punch-sub">
              {bioBusy
                ? "أكّد بصمتك…"
                : blocked
                ? windowText(data.punch_window, data.company.timezone, offLabel(calendar))
                : state.phase === "locating"
                ? "جارٍ تحديد الموقع…"
                : state.phase === "submitting"
                  ? "جارٍ الإرسال للخادم…"
                  : !online
                    ? "سيُحفظ على الجهاز"
                    : forgot
                      ? "لم يُسجَّل حضورك — تظهر الحركة للمراجعة"
                      : null}
            </span>
            </span>
          </button>
        )}


        {state.phase === "ready" && online && fromCache === null && data.can_check_out_without_in && !forgot && waiting.length === 0 && !setupNeeded && (
          <button className="btn ghost forgot-in" onClick={() => setConfirmNoIn(true)} disabled={working || bioBusy}>
            نسيت تسجيل الحضور؟ سجّل الانصراف فقط
          </button>
        )}
        {confirmNoIn && (
          <Modal title="تسجيل انصراف بدون حضور" onClose={() => setConfirmNoIn(false)}>
            <p>لم يُسجَّل حضورك. سيُسجَّل الانصراف فقط، وتظهر الحركة للإدارة للمراجعة.</p>
            <div className="row">
              <button className="btn primary" onClick={() => { setConfirmNoIn(false); void onTap(data, false, "check_out"); }}>تسجيل الانصراف</button>
              <button className="btn ghost" onClick={() => setConfirmNoIn(false)}>إلغاء</button>
            </div>
          </Modal>
        )}
        {state.phase === "ready" && state.notice && (
          <Banner kind={state.notice.kind} onClose={() => dispatch({ type: "DISMISS_NOTICE" })}>{state.notice.text}</Banner>
        )}
        {gpsNote && (
          <Banner kind="error" className="gps-note" onClose={() => setGpsNote(null)}>{gpsNote}</Banner>
        )}
        {bioNote && (
          <Banner kind={bioNote.kind} className="bio-note" onClose={() => setBioNote(null)}>{bioNote.text}</Banner>
        )}
        {data.biometric?.policy === "required" && !data.biometric.has_device && !setupNeeded && unsupportedNote && (
          <p className="hint-line">هذا الجهاز لا يدعم البصمة؛ ستُعلَّم بصماتك للمراجعة</p>
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

        <section className="quick" aria-labelledby="quick-title">
          <h3 id="quick-title" className="section-title">طلب جديد</h3>
          <div className="quick-row">
            <button className="quick-btn" onClick={() => onNewRequest("leave")} disabled={!online}>
              <Icon name="calendar" />إجازة
            </button>
            <button className="quick-btn" onClick={() => onNewRequest("permission")} disabled={!online}>
              <Icon name="clock" />إذن
            </button>
            <button className="quick-btn" onClick={() => onNewRequest("other")} disabled={!online}>
              <Icon name="doc" />طلب آخر
            </button>
          </div>
        </section>

        <EarlierDays days={days} timeZone={tz} />

        {install && (
          <button className="btn ghost block" onClick={install}>تثبيت التطبيق على الجهاز</button>
        )}
      </main>
    </div>
  );
}

/** A check-out with no check-in before it (the employee forgot to check in). */
function noCheckIn(rows: CardRow[], i: number): boolean {
  return rows[i].action === "check_out" && rows[i].kind === "stamped" && (i === 0 || rows[i - 1].action === "check_out");
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
function ServerClock({ offsetMs, timeZone, rows, openStart }: {
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
    <div className="clock-block">
      <p className="clock">
        <span className="sr-only">الساعة الآن {formatClock(iso, timeZone)}</span>
        <span dir="ltr" aria-hidden="true">
          <span className="clock-hm">{c.hm}</span>
          <span className="clock-s">:{c.ss}</span>
          <span className="clock-ap">{c.period}</span>
        </span>
      </p>
      <p className="clock-date">{formatDate(iso, timeZone)}</p>
      {worked > 0 && (
        <p className="worked">مدة العمل اليوم <span>{formatDuration(worked)}</span></p>
      )}
    </div>
  );
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
