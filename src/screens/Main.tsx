import { useState } from "react";
import type { SessionUser } from "../lib/api";
import { Home } from "./Home";
import { useOnline } from "./hooks";
import { Requests } from "./Requests";
import { useRequests } from "./useRequests";

type Tab = "today" | "requests";

/** The signed-in app: two tabs. "Today" stays mounted when hidden, so offline punches keep syncing. */
export function Main({ user }: { user: SessionUser }) {
  const [tab, setTab] = useState<Tab>("today");
  const [visited, setVisited] = useState(false);
  const online = useOnline();
  const requests = useRequests();
  const count = requests.overview?.inbox_count ?? 0;

  const go = (t: Tab) => {
    setTab(t);
    if (t === "requests") {
      setVisited(true);
      requests.reload();
    }
    window.scrollTo(0, 0);
  };

  return (
    <div className="with-tabs">
      <div hidden={tab !== "today"}>
        <Home user={user} />
      </div>
      {visited && (
        <div className="app" hidden={tab !== "requests"}>
          <Requests data={requests} online={online} />
        </div>
      )}
      <nav className="tabbar" aria-label="التنقل">
        <button className={`tab${tab === "today" ? " on" : ""}`} aria-current={tab === "today" ? "page" : undefined} onClick={() => go("today")}>
          <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="3.5" width="16" height="17" rx="2" /><path d="M8 8.5h8M8 12.5h8M8 16.5h4" /></svg>
          <span>اليوم</span>
        </button>
        <button className={`tab${tab === "requests" ? " on" : ""}`} aria-current={tab === "requests" ? "page" : undefined} onClick={() => go("requests")}>
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 3.5h7l4 4v13H7z" /><path d="M14 3.5v4h4M10 12.5h5M10 16h5" /></svg>
          <span>الطلبات</span>
          {count > 0 && <span className="badge" aria-label={`${count} بانتظار موافقتك`}>{count}</span>}
        </button>
      </nav>
    </div>
  );
}
