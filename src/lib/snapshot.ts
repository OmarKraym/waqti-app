// A copy of server data on this phone, per account: shown at once, and with no connection (the screen says how old it is).
// Replaced every time the data loads online. Nothing here throws.
type Store = Pick<Storage, "getItem" | "setItem">;
const KEY = (kind: string, userId: string) => `waqti-snap:${kind}:${userId}`;

function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function saveSnapshot(kind: string, userId: string, data: unknown, now = Date.now(), store: Store | null = defaultStore()): void {
  try {
    store?.setItem(KEY(kind, userId), JSON.stringify({ data, saved_at_ms: now }));
  } catch {
    /* blocked or full storage: the screen just needs the internet */
  }
}

export function loadSnapshot<T>(kind: string, userId: string, store: Store | null = defaultStore()): { data: T; saved_at_ms: number } | null {
  try {
    const raw = store?.getItem(KEY(kind, userId));
    if (!raw) return null;
    const v = JSON.parse(raw) as { data?: unknown; saved_at_ms?: unknown };
    return v && v.data !== undefined && v.data !== null && typeof v.saved_at_ms === "number"
      ? { data: v.data as T, saved_at_ms: v.saved_at_ms }
      : null;
  } catch {
    return null;
  }
}
