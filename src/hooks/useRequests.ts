import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../lib/client";
import { AppError } from "../lib/errors";
import { loadSnapshot, saveSnapshot } from "../lib/snapshot";
import type { InboxItem, OvertimeOverview, RequestsOverview } from "../lib/types";

type Saved = { overview: RequestsOverview; inbox: InboxItem[]; overtime: OvertimeOverview | null };

export interface RequestsData {
  overview: RequestsOverview | null;
  inbox: InboxItem[];
  /** Overtime assigned to me / by me (null until loaded, or if it failed: requests still work). */
  overtime: OvertimeOverview | null;
  loading: boolean;
  error: AppError | null;
  /** When the data on screen is the copy saved on this phone (the server could not be reached): when it was saved. */
  savedAt: number | null;
  reload: () => Promise<void>;
}

/**
 * Requests and the approval inbox, loaded once for the whole app (the tab badge needs the count).
 * Reloads when the app comes back to the front or the connection returns.
 */
export function useRequests(userId: string): RequestsData {
  // The last copy saved on this phone shows at once (and with no connection) until the server answers.
  const [kept] = useState(() => loadSnapshot<Saved>("requests", userId));
  const [overview, setOverview] = useState<RequestsOverview | null>(kept?.data.overview ?? null);
  const [inbox, setInbox] = useState<InboxItem[]>(kept?.data.inbox ?? []);
  const [overtime, setOvertime] = useState<OvertimeOverview | null>(kept?.data.overtime ?? null);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<AppError | null>(null);
  const run = useRef(0);

  const reload = useCallback(async () => {
    const mine = ++run.current;
    setLoading(true);
    try {
      const [o, ot] = await Promise.all([api.getRequestsOverview(), api.getOvertimeOverview().catch(() => null)]);
      // Only approvers have an inbox: skip the second call for everyone else.
      const box = o.inbox_count > 0 ? await api.getInbox() : [];
      if (mine !== run.current) return;
      setOverview(o);
      setInbox(box);
      if (ot) setOvertime(ot);
      saveSnapshot("requests", userId, { overview: o, inbox: box, overtime: ot ?? loadSnapshot<Saved>("requests", userId)?.data.overtime ?? null });
      setSavedAt(null);
      setError(null);
    } catch (e) {
      if (mine !== run.current) return;
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      if (err.code === "not_authenticated") return void api.signOut();
      setError(err);
      if (err.code === "network") setSavedAt(loadSnapshot<Saved>("requests", userId)?.saved_at_ms ?? null);
    } finally {
      if (mine === run.current) setLoading(false);
    }
  }, [userId]);

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

  return { overview, inbox, overtime, loading, error, savedAt, reload };
}
