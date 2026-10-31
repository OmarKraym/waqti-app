import { useEffect, useState } from "react";
import type { SessionUser } from "../lib/api";
import { api } from "../lib/client";
import { currentSubscription, keysOf } from "../lib/push";
import { Home } from "./Home";
import { useOnline } from "./hooks";
import { Notifications } from "./Notifications";
import { Requests } from "./Requests";
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

/** The signed-in app: three tabs. "Today" stays mounted when hidden, so offline punches keep syncing. */
export function Main({ user }: { user: SessionUser }) {
  const [tab, setTab] = useState<Tab>(() => tabFromUrl(window.location.href) ?? "today");
  const [visited, setVisited] = useState<Set<Tab>>(() => new Set([tab]));
  const online = useOnline();
  const requests = useRequests();
  const count = requests.overview?.inbox_count ?? 0;

  const go = (t: Tab) => {
    setTab(t);
    setVisited((v) => (v.has(t) ? v : new Set(v).add(t)));
    if (t === "requests") requests.reload();
    window.scrollTo(0, 0);
  };

  useEffect(() => {
    // Opened from a notification: clean the address, keep the tab.
    if (tabFromUrl(window.location.href)) window.history.replaceState(null, "", window.location.pathname);
    // A notification tapped while the app is already open.
    const onMessage = (e: MessageEvent) => {
      if (e.data?.type === "waqti-open") {
        const t = tabFromUrl(String(e.data.url ?? ""));
        if (t) go(t);
      }
    };
    navigator.serviceWorker?.addEventListener("message", onMessage);
    // This phone already allowed notifications: make sure the server knows it belongs to THIS account.
    if ("Notification" in window && Notification.permission === "granted" && navigator.onLine) {
      currentSubscription().then((sub) => sub && api.savePushSubscription(keysOf(sub))).catch(() => undefined);
    }
    return () => navigator.serviceWorker?.removeEventListener("message", onMessage);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per sign-in
  }, [user.id]);

  return (
    <div className="with-tabs">
      <div hidden={tab !== "today"}>
        <Home user={user} />
      </div>
      {visited.has("requests") && (
        <div className="app" hidden={tab !== "requests"}>
          <Requests data={requests} online={online} />
        </div>
      )}
      {visited.has("notifications") && (
        <div className="app" hidden={tab !== "notifications"}>
          <Notifications online={online} />
        </div>
      )}
      <nav className="tabbar three" aria-label="التنقل">
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
    </div>
  );
}
