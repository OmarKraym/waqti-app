import { useEffect, useState } from "react";
import type { SessionUser } from "../lib/api";
import { ERROR_TEXT } from "../lib/errors";
import { failedOf, isQueuedEvent, pendingOf, withQueue } from "../lib/offlineQueue";
import { windowText } from "../lib/punchWindow";
import { holidayBanner, offLabel } from "../lib/calendar";
import { earlierDays, todayRows } from "../lib/timecard";
import { jobLine, loadSummary, saveSummary, todayShift } from "../lib/profileSummary";
import { api } from "../lib/client";
import type { ProfileSummary } from "../lib/types";
import { effectiveAction, isPunchLocked, lockedText } from "../lib/punchMode";
import { useAttendance } from "../hooks/useAttendance";
import { Banner, Button, Icon, IconButton, Modal } from "../components";
import { DeviceSetup } from "./DeviceSetup";
import { ConfirmSignOut, type ProfileInfo } from "./Profile";
import { EarlierDays } from "./home/EarlierDays";
import { FailedPunches } from "./home/FailedPunches";
import { PunchButton } from "./home/PunchButton";
import { StatusCard } from "./home/StatusCard";
import { Timecard } from "./home/Timecard";

const OFFLINE_PUNCHES = false;

/** The today screen: the container. What it does lives in useAttendance; what it shows lives in ./home/. */
export function Home({ user, onOpenProfile, onOpenNotifications, setupMissing = false, onInfo }: {
  user: SessionUser;
  /** The avatar at the top opens the profile. */
  onOpenProfile: () => void;
  /** The bell at the top opens reminders and holidays. */
  onOpenNotifications: () => void;
  /** Notifications or location are not set up on this phone: a dot on the bell. */
  setupMissing?: boolean;
  /** Who the employee is (shown on the profile screen). */
  onInfo: (info: ProfileInfo) => void;
}) {
  const a = useAttendance({ user, onInfo });
  const { state, online } = a;
  const [confirmNoIn, setConfirmNoIn] = useState(false); // phase 13: confirm "check out without a check-in"
  const [confirmOut, setConfirmOut] = useState(false); // only used by the load-error screen (the profile has its own button)
  // Job title, department and today's hours come from "my data summary" (only what the company allows). The copy saved on
  // this phone shows at once; it is refreshed once per visit when online (the profile refreshes it too).
  const [summary, setSummary] = useState<ProfileSummary | null>(() => loadSummary(user.id)?.data ?? null);
  useEffect(() => {
    if (!a.online) return;
    let alive = true;
    api.getProfileSummary().then((fresh) => { if (!alive) return; saveSummary(user.id, fresh); setSummary(fresh); }).catch(() => undefined);
    return () => { alive = false; };
  }, [user.id, a.online]);

  if (state.phase === "loading") {
    return (
      <div className="center-screen" aria-busy="true">
        <div className="spinner" />
        <p className="u-muted">جارٍ تحميل حالتك…</p>
      </div>
    );
  }

  if (state.phase === "load_error") {
    return (
      <main className="center-screen">
        <div className="card pad">
          <Icon name="alert" className="pad__icon" />
          <h2 className="pad__title">تعذّر تحميل حالة الحضور</h2>
          <p className="u-muted">
            {state.error.code === "network" ? "تحقق من اتصالك بالإنترنت." : ERROR_TEXT[state.error.code]}
          </p>
          <div className="row">
            <Button variant="primary" onClick={a.refresh}>إعادة المحاولة</Button>
            <Button variant="ghost" onClick={() => setConfirmOut(true)}>تسجيل الخروج</Button>
          </div>
        </div>
        {confirmOut && <ConfirmSignOut user={user} onCancel={() => setConfirmOut(false)} />}
      </main>
    );
  }

  const data = withQueue(state.data, a.queue);
  // Offline punching is switched off (security audit SEC-001: the server cannot prove a phone's clock, so a
  // punch is only recorded while the server can stamp it). Punches saved on a phone before this change are
  // still sent once; the server refuses them and they are listed below for the company to correct.
  const allowQueue = OFFLINE_PUNCHES && a.storage !== null && a.anchor.current !== null;
  const waiting = pendingOf(a.queue);
  const working = state.phase === "locating" || state.phase === "submitting";
  const nowMs = Date.now() + a.offsetMs;
  const action = state.phase === "ready" ? effectiveAction(data.next_action, data.punch_mode, nowMs) : state.pending.action;
  const forgot = !!data.forgot_check_in; // phase 14: the button is already "check out" (no check-in today)
  // Phase 8a: outside the allowed times the button is off (the server refuses anyway). Old cached states have no window.
  const blocked = !!data.punch_window && !data.punch_window.allowed && a.fromCache === null;
  // Phase 25 (automatic punch mode): checked in, and the check-out opens at the middle of the shift: the button waits.
  const waitingForCheckOut = state.phase === "ready" && isPunchLocked(data.punch_mode, nowMs);
  const canTap = !working && !a.bioBusy && !blocked && !waitingForCheckOut && (online || (allowQueue && !data.forgot_check_in));
  const tz = data.company.timezone;
  const rows = todayRows(data.recent_events, data.open_session?.started_at ?? null, nowMs, tz);
  const days = earlierDays(data.recent_events.filter((e) => !isQueuedEvent(e)), nowMs, tz, 10);
  const initial = data.employee.full_name.trim().charAt(0) || "؟";
  const punchSub = a.bioBusy
    ? "أكّد بصمتك…"
    : blocked
      ? windowText(data.punch_window, data.company.timezone, offLabel(a.calendar))
      : state.phase === "locating"
        ? "جارٍ تحديد الموقع…"
        : state.phase === "submitting"
          ? "جارٍ الإرسال للخادم…"
          : waitingForCheckOut
            ? lockedText(data.punch_mode, tz)
            : !online
              ? "سيُحفظ على الجهاز"
              : forgot
                ? "لم يُسجَّل حضورك — تظهر الحركة للمراجعة"
                : null;

  return (
    <div className="app">
      <header className="appbar appbar--home">
        <button className="who-btn" onClick={onOpenProfile} aria-label="فتح الملف الشخصي">
          <span className="avatar avatar--sm" aria-hidden="true">{initial}</span>
          <span className="who-btn__text">
            <span className="who-btn__brand">وقتي</span>
            <span className="who-btn__sub u-truncate">{data.company.name}</span>
          </span>
        </button>
        <span className="bell">
          <IconButton icon="bell" label={setupMissing ? "التنبيهات — الإعداد غير مكتمل" : "التنبيهات"} onClick={onOpenNotifications} className="icon-btn--outlined" />
          {setupMissing && <span className="bell__dot" aria-hidden="true" />}
        </span>
      </header>

      <main className="container has-punch">
        {holidayBanner(a.calendar) && <Banner kind="success">{holidayBanner(a.calendar)}</Banner>}
        {!online && (
          <Banner kind={allowQueue ? "warning" : "error"}>
            {allowQueue
              ? "لا يوجد اتصال بالإنترنت. يمكنك التسجيل وسيُحفظ على الجهاز. افتح التطبيق مع الإنترنت خلال 3 أيام ليُعتمد، ولا تغيّر ساعة الهاتف ولا تحذف التطبيق."
              : "لا يوجد اتصال بالإنترنت. تسجيل الحضور يحتاج اتصالًا."}
          </Banner>
        )}

        <StatusCard data={data} offsetMs={a.offsetMs} shift={todayShift(summary?.schedule, nowMs, tz, offLabel(a.calendar))} job={jobLine(summary)} />
        <Timecard data={data} rows={rows} offsetMs={a.offsetMs} freshId={a.freshId} />

        {a.setupNeeded ? (
          <DeviceSetup
            onDone={() => {
              a.setSetupNeeded(false);
              a.setBioNote({ kind: "success", text: "تم تسجيل البصمة لهذا الجهاز. يمكنك الآن تسجيل الحضور." });
              a.load();
            }}
          />
        ) : state.phase === "unconfirmed" ? (
          <div className="unconfirmed" role="alert">
            <p><Icon name="alert" className="icon--inline" />{ERROR_TEXT.network}</p>
            <div className="row">
              <Button variant="primary" onClick={() => a.onRetry(state.pending)}>إعادة المحاولة</Button>
              <Button variant="ghost" onClick={a.refresh}>تحديث الحالة</Button>
            </div>
          </div>
        ) : (
          <PunchButton
            action={action} fingerprint={data.biometric?.policy === "required"} sub={punchSub}
            working={working} disabled={!canTap} onTap={() => a.onTap(data, allowQueue)}
          />
        )}

        {state.phase === "ready" && online && a.fromCache === null && data.can_check_out_without_in && !forgot && waiting.length === 0 && !a.setupNeeded && (
          <Button variant="ghost" className="forgot-in" onClick={() => setConfirmNoIn(true)} disabled={working || a.bioBusy}>
            نسيت تسجيل الحضور؟ سجّل الانصراف فقط
          </Button>
        )}
        {confirmNoIn && (
          <Modal title="تسجيل انصراف بدون حضور" onClose={() => setConfirmNoIn(false)}>
            <p>لم يُسجَّل حضورك. سيُسجَّل الانصراف فقط، وتظهر الحركة للإدارة للمراجعة.</p>
            <div className="row">
              <Button variant="primary" onClick={() => { setConfirmNoIn(false); void a.onTap(data, false, "check_out"); }}>تسجيل الانصراف</Button>
              <Button variant="ghost" onClick={() => setConfirmNoIn(false)}>إلغاء</Button>
            </div>
          </Modal>
        )}
        {state.phase === "ready" && state.notice && (
          <Banner kind={state.notice.kind} onClose={() => a.dispatch({ type: "DISMISS_NOTICE" })}>{state.notice.text}</Banner>
        )}
        {a.gpsNote && <Banner kind="error" onClose={() => a.setGpsNote(null)}>{a.gpsNote}</Banner>}
        {a.bioNote && (
          <Banner kind={a.bioNote.kind} className="bio-card__note" onClose={() => a.setBioNote(null)}>{a.bioNote.text}</Banner>
        )}
        {data.biometric?.policy === "required" && !data.biometric.has_device && !a.setupNeeded && a.unsupportedNote && (
          <p className="hint">هذا الجهاز لا يدعم البصمة؛ ستُعلَّم بصماتك للمراجعة</p>
        )}
        {a.syncNote && <Banner kind={a.syncNote.kind} onClose={() => a.setSyncNote(null)}>{a.syncNote.text}</Banner>}
        {waiting.length > 0 && (
          <p className="queue-count" role="status">
            <Icon name="phone" className="icon--inline" />
            بانتظار الإرسال: {waiting.length} {online ? "— جارٍ الإرسال…" : ""}
          </p>
        )}

        <FailedPunches failed={failedOf(a.queue)} timeZone={tz} onDismiss={a.dismissFailed} />
        <EarlierDays days={days} timeZone={tz} />
      </main>
    </div>
  );
}
