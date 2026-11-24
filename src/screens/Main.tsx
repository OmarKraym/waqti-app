import { useCallback, useEffect, useState } from "react";
import type { SessionUser } from "../lib/api";
import { type Draft } from "../lib/requests";
import type { RequestType } from "../lib/types";
import { api } from "../lib/client";
import { readPushState } from "../lib/push";
import { ensureSubscription, geoPermission } from "../lib/permissions";
import { geoGrantedBefore } from "../lib/location";
import { keepStorage } from "../lib/localSettings";
import { browserStorage, loadCachedState } from "../lib/offlineQueue";
import { PermissionsSetup } from "./PermissionsSetup";
import { Home } from "./Home";
import { ConfirmSignOut, Profile, type ProfileInfo } from "./Profile";
import { useOnline } from "../hooks";
import { Notifications } from "./Notifications";
import { Requests } from "./Requests";
import { useRequests } from "../hooks/useRequests";
import { Icon } from "../components";

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

/**
 * The signed-in app (design 2026-11): two tabs, «الرئيسية» and «الطلبات». «Notifications» (reminders and holidays) is a screen
 * opened from the bell on Home or from the profile; it keeps its ?tab=notifications address so a tapped notification still opens it.
 * "Today" stays mounted when hidden, so offline punches keep syncing.
 */
export function Main({ user }: { user: SessionUser }) {
  const [tab, setTab] = useState<Tab>(() => tabFromUrl(window.location.href) ?? "today");
  const [visited, setVisited] = useState<Set<Tab>>(() => new Set([tab]));
  // Where the back arrow of the notifications screen returns.
  const [lastTab, setLastTab] = useState<Exclude<Tab, "notifications">>("today");
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

  const go = (t: Tab) => {
    if (t !== "notifications") setLastTab(t);
    setTab(t);
    setVisited((v) => (v.has(t) ? v : new Set(v).add(t)));
    // Remember the tab in the address (no new history entry), so a reload stays here.
    window.history.replaceState(window.history.state, "", urlWithTab(window.location.href, t));
    if (t === "requests") requests.reload();
    window.scrollTo(0, 0);
  };
  const openNotifications = () => {
    if (profile) closeProfile();
    go("notifications");
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
          setupMissing={missing} onOpenSetup={() => setSetupOpen(true)} onOpenNotifications={openNotifications}
          onLoginChanged={(enabled) => setInfo((i) => (i ? { ...i, biometric: { ...i.biometric, login_enabled: enabled } } : i))}
        />
      )}
      <div hidden={profile || tab !== "today"}>
        <Home
          user={user} onNewRequest={newRequest} onOpenProfile={openProfile} onInfo={setInfo}
          onOpenNotifications={openNotifications} setupMissing={missing}
        />
      </div>
      {visited.has("requests") && (
        <div className="app" hidden={profile || tab !== "requests"}>
          <Requests data={requests} online={online} compose={compose} />
        </div>
      )}
      {visited.has("notifications") && (
        <div className="app" hidden={profile || tab !== "notifications"}>
          <Notifications online={online} userId={user.id} onBack={() => go(lastTab)} />
        </div>
      )}
      <nav className="tabbar" aria-label="التنقل الرئيسي" hidden={profile || tab === "notifications"}>
        <button className={`tab${tab === "today" ? " is-active" : ""}`} aria-current={tab === "today" ? "page" : undefined} onClick={() => go("today")}>
          <Icon name={tab === "today" ? "homeFill" : "home"} />
          <span>الرئيسية</span>
        </button>
        <button className={`tab${tab === "requests" ? " is-active" : ""}`} aria-current={tab === "requests" ? "page" : undefined} onClick={() => go("requests")}>
          <Icon name={tab === "requests" ? "assignmentFill" : "assignment"} />
          <span>الطلبات</span>
          {count > 0 && <span className="badge" aria-label={`${count} بانتظار موافقتك`}>{count}</span>}
        </button>
      </nav>

      {confirmOut && <ConfirmSignOut user={user} onCancel={() => setConfirmOut(false)} />}
    </div>
  );
}
