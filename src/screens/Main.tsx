import { useCallback, useEffect, useRef, useState } from "react";
import type { SessionUser } from "../lib/api";
import { lateNote, lateOfferFrom, shouldAskLateStatus, type LateOffer } from "../lib/lateOffer";
import { formatMinutes, formatTimes, type Draft } from "../lib/requests";
import type { PunchResult, RequestType } from "../lib/types";
import { api } from "../lib/client";
import { readPushState } from "../lib/push";
import { ensureSubscription, geoPermission } from "../lib/permissions";
import { geoGrantedBefore } from "../lib/location";
import { keepStorage } from "../lib/localSettings";
import { browserStorage, loadCachedState } from "../lib/offlineQueue";
import { PermissionsSetup } from "./PermissionsSetup";
import { Home } from "./Home";
import { ConfirmSignOut, Profile, type ProfileInfo } from "./Profile";
import { useOnline } from "./hooks";
import { Notifications } from "./Notifications";
import { Requests } from "./Requests";
import { Banner, Modal } from "./ui";
import { useRequests } from "./useRequests";

type Tab = "today" | "requests" | "notifications";

/** ?tab=requests (from a tapped notification) -> that tab. */
export function tabFromUrl(href: string): Tab | null {
  try {
    const t = new URL(href, "https://x/").searchParams.get("tab");
    return t === "requests" || t === "notifications" || t === "today" ? t : null;
  } catch {
    return null;
  }
}

/** The address for a tab: ?tab=… (other parameters kept), none for "today". A reload opens the same tab. */
export function urlWithTab(href: string, tab: Tab): string {
  const u = new URL(href, "https://x/");
  if (tab === "today") u.searchParams.delete("tab");
  else u.searchParams.set("tab", tab);
  return u.pathname + u.search + u.hash;
}

/** The signed-in app: three tabs. "Today" stays mounted when hidden, so offline punches keep syncing. */
export function Main({ user }: { user: SessionUser }) {
  const [tab, setTab] = useState<Tab>(() => tabFromUrl(window.location.href) ?? "today");
  const [visited, setVisited] = useState<Set<Tab>>(() => new Set([tab]));
  const online = useOnline();
  const requests = useRequests(user.id);
  const count = requests.overview?.inbox_count ?? 0;
  // "New request" from the today screen: open the requests tab on the form, with the type already chosen.
  const [compose, setCompose] = useState<{ n: number; type: RequestType; draft?: Draft } | null>(null);

  // Profile screen (opened from the logo). It gets its own history entry, so the phone's back button closes it.
  const [profile, setProfile] = useState(false);
  const [info, setInfo] = useState<ProfileInfo | null>(null);
  const [confirmOut, setConfirmOut] = useState(false);
  const openProfile = () => {
    window.history.pushState({ ...(window.history.state ?? {}), profile: true }, "", window.location.href);
    setProfile(true);
    window.scrollTo(0, 0);
  };
  const closeProfile = () => {
    if (window.history.state?.profile) window.history.back();
    else setProfile(false);
  };
  useEffect(() => {
    const onPop = () => { setProfile(!!window.history.state?.profile); setConfirmOut(false); };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  // After a check-in the SERVER says what to do about a late arrival (employee_late_status): offer a justification in a
  // dialog, or, when he is late but cannot request one (none left, too long, already requested), say why in a line.
  // Whatever goes wrong here (offline, an older server, an error) is silent: the punch is already saved.
  const [lateOffer, setLateOffer] = useState<LateOffer | null>(null);
  const [lateInfo, setLateInfo] = useState<string | null>(null);
  const punchSeq = useRef(0);
  const onPunched = useCallback(async (result: PunchResult) => {
    const mine = ++punchSeq.current;     // a newer punch makes an older, slower answer obsolete
    setLateInfo(null);
    if (!shouldAskLateStatus(result)) return;
    try {
      const status = await api.getLateStatus(result.event_id);
      if (!status || mine !== punchSeq.current) return;
      // The company clock decides the day and the arrival time on the form. It is in the state saved on this phone
      // (the punch screen has just loaded it); without it no form is prepared rather than one with a guessed time.
      const timeZone = loadCachedState(browserStorage(), user.id)?.data.company.timezone;
      const offer = timeZone ? lateOfferFrom(status, result.server_time, timeZone) : null;
      if (offer) setLateOffer(offer);
      else setLateInfo(lateNote(status));
    } catch {
      // no decision: offline, the database is older than the app, or an error — he can still request it from the requests tab
    }
  }, [user.id]);

  const go = (t: Tab) => {
    setTab(t);
    setVisited((v) => (v.has(t) ? v : new Set(v).add(t)));
    // Remember the tab in the address (no new history entry), so a reload stays here.
    window.history.replaceState(window.history.state, "", urlWithTab(window.location.href, t));
    if (t === "requests") requests.reload();
    window.scrollTo(0, 0);
  };
  const newRequest = (type: RequestType, draft?: Draft) => {
    setCompose((c) => ({ n: (c?.n ?? 0) + 1, type, draft }));
    go("requests");
  };

  useEffect(() => {
    // The address keeps ?tab= (from a notification or a reload), so the next reload opens the same tab.
    // A notification tapped while the app is already open.
    const onMessage = (e: MessageEvent) => {
      if (e.data?.type === "waqti-open") {
        const t = tabFromUrl(String(e.data.url ?? ""));
        if (t) go(t);
      }
    };
    navigator.serviceWorker?.addEventListener("message", onMessage);
    // Every start: if this phone allowed notifications, keep it subscribed (a lost subscription is renewed) and make
    // sure the server knows it belongs to THIS account. Never asks by itself.
    if ("Notification" in window && "serviceWorker" in navigator && navigator.onLine) {
      navigator.serviceWorker.ready
        .then((reg) => ensureSubscription({ permission: Notification.permission, pushManager: reg.pushManager }))
        .then((keys) => keys && api.savePushSubscription(keys))
        .catch(() => undefined);
    }
    // Ask the browser not to delete the data saved on this phone (settings, last state) when space runs low.
    void keepStorage();
    return () => navigator.serviceWorker?.removeEventListener("message", onMessage);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per sign-in
  }, [user.id]);

  // Something from the first-run setup is still missing on this phone (location blocked, notifications off).
  const [setupOpen, setSetupOpen] = useState(false);
  const [missing, setMissing] = useState(false);
  const checkMissing = useCallback(async () => {
    const policy = loadCachedState(browserStorage(), user.id)?.data.location_policy ?? "none";
    // Location allowed once on this phone = done (a switched-off GPS later is not a setup problem).
    const geoDone = policy === "none" || geoGrantedBefore();
    const [push, geo] = await Promise.all([readPushState(), geoDone ? Promise.resolve("granted" as const) : geoPermission()]);
    setMissing(push === "off" || push === "ios_install" || push === "denied" || geo === "denied" || geo === "prompt");
  }, [user.id]);
  useEffect(() => { void checkMissing(); }, [checkMissing]);

  if (setupOpen) {
    const cached = loadCachedState(browserStorage(), user.id)?.data;
    return (
      <PermissionsSetup
        user={user}
        locationPolicy={cached?.location_policy ?? "geofence"}
        biometric={cached?.biometric}
        onDone={() => { setSetupOpen(false); void checkMissing(); }}
      />
    );
  }

  return (
    <div className="with-tabs">
      {profile && (
        <Profile
          user={user} info={info} online={online} onBack={closeProfile} onSignOut={() => setConfirmOut(true)}
          setupMissing={missing} onOpenSetup={() => setSetupOpen(true)}
          onLoginChanged={(enabled) => setInfo((i) => (i ? { ...i, biometric: { ...i.biometric, login_enabled: enabled } } : i))}
        />
      )}
      <div hidden={profile || tab !== "today"}>
        <Home user={user} onNewRequest={newRequest} onOpenProfile={openProfile} onInfo={setInfo} onPunched={onPunched} />
      </div>
      {visited.has("requests") && (
        <div className="app" hidden={profile || tab !== "requests"}>
          <Requests data={requests} online={online} compose={compose} />
        </div>
      )}
      {visited.has("notifications") && (
        <div className="app" hidden={profile || tab !== "notifications"}>
          <Notifications online={online} userId={user.id} />
        </div>
      )}
      {lateInfo && !profile && (
        <div className="late-note"><Banner kind="warning" onClose={() => setLateInfo(null)}>{lateInfo}</Banner></div>
      )}
      <nav className="tabbar three" aria-label="التنقل" hidden={profile}>
        <button className={`tab${tab === "today" ? " on" : ""}`} aria-current={tab === "today" ? "page" : undefined} onClick={() => go("today")}>
          <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="3.5" width="16" height="17" rx="2" /><path d="M8 8.5h8M8 12.5h8M8 16.5h4" /></svg>
          <span>اليوم</span>
        </button>
        <button className={`tab${tab === "requests" ? " on" : ""}`} aria-current={tab === "requests" ? "page" : undefined} onClick={() => go("requests")}>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 3.5h7l4 4v13H7z" /><path d="M14 3.5v4h4M10 12.5h5M10 16h5" /></svg>
          <span>الطلبات</span>
          {count > 0 && <span className="badge" aria-label={`${count} بانتظار موافقتك`}>{count}</span>}
        </button>
        <button className={`tab${tab === "notifications" ? " on" : ""}`} aria-current={tab === "notifications" ? "page" : undefined} onClick={() => go("notifications")}>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z" /><path d="M10 20.5a2 2 0 0 0 4 0" /></svg>
          <span>الإشعارات</span>
        </button>
      </nav>

      {lateOffer && (
        <Modal title="تأخرت اليوم" onClose={() => setLateOffer(null)}>
          <p className="modal-text">
            وصلت متأخرًا عن بداية دوامك، والمحسوب عليك {formatMinutes(lateOffer.minutes)}. يمكنك تقديم تبرير تأخير الآن.
            {lateOffer.left !== null && ` المتبقي لك هذا الشهر: ${formatTimes(lateOffer.left)}.`}
          </p>
          <div className="modal-actions">
            <button className="btn primary" onClick={() => { const d = lateOffer.draft; setLateOffer(null); newRequest("permission", d); }}>تقديم تبرير</button>
            <button className="btn ghost" onClick={() => setLateOffer(null)}>ليس الآن</button>
          </div>
        </Modal>
      )}
      {confirmOut && <ConfirmSignOut user={user} onCancel={() => setConfirmOut(false)} />}
    </div>
  );
}
