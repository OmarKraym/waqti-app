import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import {
  actionLabel,
  clockOffsetMs,
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
import type { AttendanceEvent, AttendanceState, LocationStatus } from "../lib/types";
import { useInstallPrompt, useIosInstallHint, useOnline } from "./hooks";

export function Home() {
  const [state, dispatch] = useReducer(reduce, initialState);
  const busy = useRef(false); // blocks a second tap while one is being processed
  const online = useOnline();
  const install = useInstallPrompt();
  const [iosHint, dismissIosHint] = useIosInstallHint();
  const [hint, setHint] = useState<string | null>(null);

  const load = useCallback(async () => {
    dispatch({ type: "LOAD_START" });
    try {
      dispatch({ type: "LOAD_OK", data: await api.getAttendanceState() });
    } catch (e) {
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      if (err.code === "not_authenticated") return void api.signOut();
      dispatch({ type: "LOAD_FAIL", error: err });
    }
  }, []);

  useEffect(() => {
    load();
    // Coming back to the app: refresh from the server (the status may have changed on another device).
    const onVisible = () => document.visibilityState === "visible" && load();
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  const submit = useCallback(
    async (pending: Pending) => {
      try {
        const result = await api.punch({
          request_id: pending.request_id,
          expected_action: pending.action,
          reading: pending.reading ?? { kind: "not_requested" },
        });
        dispatch({ type: "PUNCH_OK", result });
        load(); // confirm the new state from the server
      } catch (e) {
        const err = e instanceof AppError ? e : new AppError("unknown", String(e));
        if (err.code === "not_authenticated") return void api.signOut();
        dispatch({ type: "PUNCH_FAIL", error: err });
        if (err.code === "state_changed") load();
      } finally {
        busy.current = false;
      }
    },
    [load],
  );

  async function onTap(data: AttendanceState) {
    if (busy.current) return;
    busy.current = true;
    setHint(null);
    const pending: Pending = { request_id: newRequestId(), action: data.next_action, reading: null };
    dispatch({ type: "TAP", request_id: pending.request_id });
    const reading = await readLocation(data.location_policy);
    setHint(readingHint(reading, data.max_accuracy_m));
    dispatch({ type: "LOCATED", reading });
    await submit({ ...pending, reading });
  }

  async function onRetry(pending: Pending) {
    if (busy.current) return;
    busy.current = true;
    dispatch({ type: "RETRY" });
    await submit(pending); // same request_id: the server will not record it twice
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
            <button className="btn primary" onClick={load}>إعادة المحاولة</button>
            <button className="btn ghost" onClick={() => api.signOut()}>تسجيل الخروج</button>
          </div>
        </div>
      </main>
    );
  }

  const { data } = state;
  const working = state.phase === "locating" || state.phase === "submitting";
  const action = state.phase === "ready" ? data.next_action : state.pending.action;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <img src={`${import.meta.env.BASE_URL}icons/icon.svg`} alt="" width={28} height={28} />
          <span className="truncate">{data.company.name}</span>
        </div>
        <button className="btn ghost small" onClick={() => api.signOut()}>خروج</button>
      </header>

      <main className="container">
        {!online && (
          <div className="banner error" role="alert">لا يوجد اتصال بالإنترنت. تسجيل الحضور يحتاج اتصالًا.</div>
        )}

        <section className="card hello">
          <div className="min-w-0">
            <p className="muted small">مرحبًا</p>
            <h2 className="truncate">{data.employee.full_name}</h2>
          </div>
          {data.employee.employee_number && <span className="chip" dir="ltr">#{data.employee.employee_number}</span>}
        </section>

        <ServerClock serverIso={data.server_time} timeZone={data.company.timezone} />

        <section className="card punch-card">
          <p className="status-line">
            {data.open_session
              ? `حاضر منذ ${formatTime(data.open_session.started_at, data.company.timezone)}`
              : "لا يوجد حضور مسجّل الآن"}
          </p>

          {state.phase === "unconfirmed" ? (
            <div className="unconfirmed" role="alert">
              <p>{ERROR_TEXT.network}</p>
              <div className="row">
                <button className="btn primary" onClick={() => onRetry(state.pending)}>إعادة المحاولة</button>
                <button className="btn ghost" onClick={load}>تحديث الحالة</button>
              </div>
            </div>
          ) : (
            <button
              className={`punch ${action === "check_in" ? "in" : "out"}`}
              onClick={() => onTap(data)}
              disabled={working || !online /* a stale tap is still safe: the server checks expected_action */}
              aria-busy={working}
            >
              <span className="punch-label">{actionLabel(action)}</span>
              <span className="punch-sub">
                {state.phase === "locating"
                  ? "جارٍ تحديد الموقع…"
                  : state.phase === "submitting"
                    ? "جارٍ الإرسال للخادم…"
                    : "اضغط مرة واحدة"}
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
        </section>

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

function ServerClock({ serverIso, timeZone }: { serverIso: string; timeZone: string }) {
  const offset = useRef(clockOffsetMs(serverIso));
  const [now, setNow] = useState(() => Date.now() + offset.current);
  useEffect(() => {
    offset.current = clockOffsetMs(serverIso);
    setNow(Date.now() + offset.current);
    const t = setInterval(() => setNow(Date.now() + offset.current), 1000);
    return () => clearInterval(t);
  }, [serverIso]);
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
              {e.needs_review && <span className="chip warn">{STATUS_TEXT[e.location_status] ?? "مراجعة"}</span>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
