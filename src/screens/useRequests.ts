import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../lib/client";
import { AppError } from "../lib/errors";
import type { InboxItem, RequestsOverview } from "../lib/types";

export interface RequestsData {
  overview: RequestsOverview | null;
  inbox: InboxItem[];
  loading: boolean;
  error: AppError | null;
  reload: () => Promise<void>;
}

/**
 * Requests and the approval inbox, loaded once for the whole app (the tab badge needs the count).
 * Reloads when the app comes back to the front or the connection returns.
 */
export function useRequests(): RequestsData {
  const [overview, setOverview] = useState<RequestsOverview | null>(null);
  const [inbox, setInbox] = useState<InboxItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<AppError | null>(null);
  const run = useRef(0);

  const reload = useCallback(async () => {
    const mine = ++run.current;
    setLoading(true);
    try {
      const o = await api.getRequestsOverview();
      // Only approvers have an inbox: skip the second call for everyone else.
      const box = o.inbox_count > 0 ? await api.getInbox() : [];
      if (mine !== run.current) return;
      setOverview(o);
      setInbox(box);
      setError(null);
    } catch (e) {
      if (mine !== run.current) return;
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      if (err.code === "not_authenticated") return void api.signOut();
      setError(err);
    } finally {
      if (mine === run.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
    const onVisible = () => document.visibilityState === "visible" && reload();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", reload);
    return () => {
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", reload);
    };
  }, [reload]);

  return { overview, inbox, loading, error, reload };
}
