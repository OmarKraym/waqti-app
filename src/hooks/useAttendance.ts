import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import type { SessionUser } from "../lib/api";
import { initialState, newRequestId, reduce, type Pending } from "../lib/attendance";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { gpsPrompt, readLocation } from "../lib/location";
import {
  anchorFromCache,
  anchorFromServer,
  anchorOffsetMs,
  browserStorage,
  loadCachedState,
  loadQueue,
  makeQueuedPunch,
  pendingOf,
  saveCachedState,
  saveQueue,
  syncQueue,
  type QueuedPunch,
  type TimeAnchor,
} from "../lib/offlineQueue";
import { biometricStep, fingerprintTicket, supportsPlatformAuthenticator } from "../lib/biometric";
import { nextBoundaryMs } from "../lib/punchWindow";
import { loadCalendar, saveCalendar, type Calendar } from "../lib/calendar";
import type { AttendanceAction, AttendanceState, PunchResult } from "../lib/types";
import type { ProfileInfo } from "../screens/Profile";
import { useOnline } from "./index";

const SYNC_EVERY_MS = 30_000;

export type Note = { kind: "success" | "warning" | "error"; text: string };

/**
 * Everything the today screen does, without its markup: the server state and its cached copy, the queue of punches
 * saved on the phone and its sync loop, the signed server time, the GPS and fingerprint steps of a punch, and the
 * notes those steps leave for the screen.
 */
export function useAttendance({ user, onInfo, onPunched }: {
  user: SessionUser;
  onInfo: (info: ProfileInfo) => void;
  onPunched: (result: PunchResult) => void;
}) {
  const [state, dispatch] = useReducer(reduce, initialState);
  const busy = useRef(false); // blocks a second tap while one is being processed
  const online = useOnline();

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
  const [syncNote, setSyncNote] = useState<Note | null>(null);
  // The event just confirmed by the server: its stamp "lands" once (the only animation).
  const [freshId, setFreshId] = useState<string | null>(null);
  const syncing = useRef(false);
  // Fingerprint (phase 8b): register this phone first / the check before a punch.
  const [setupNeeded, setSetupNeeded] = useState(false);
  const [bioBusy, setBioBusy] = useState(false);
  const [gpsNote, setGpsNote] = useState<string | null>(null);
  const [bioNote, setBioNote] = useState<Note | null>(null);

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

  return {
    state, dispatch, online, storage, queue, anchor, offsetMs, fromCache, freshId, calendar,
    setupNeeded, setSetupNeeded, bioBusy, unsupportedNote,
    gpsNote, setGpsNote, bioNote, setBioNote, syncNote, setSyncNote,
    load, refresh, onTap, onRetry, dismissFailed,
  };
}
