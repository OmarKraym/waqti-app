// The phone's own secret for "this account opens only on this phone" (phase 16d). The server keeps only its hash.
// It is never shown and never sent anywhere else; if the browser data is cleared the phone is "new" and the admin
// must unbind the old one.
type Store = Pick<Storage, "getItem" | "setItem">;
const KEY = "waqti-device-key";

function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

function randomKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** This phone's key (created the first time). null when the phone cannot keep it (blocked storage). */
export function getDeviceKey(store: Store | null = defaultStore()): string | null {
  try {
    if (!store) return null;
    const have = store.getItem(KEY);
    if (have && /^[A-Za-z0-9_-]{43}$/.test(have)) return have;
    const k = randomKey();
    store.setItem(KEY, k);
    return store.getItem(KEY) === k ? k : null;
  } catch {
    return null;
  }
}

/**
 * iPhone/iPad page opened in Safari, not from the Home Screen icon. Safari and the installed app keep SEPARATE
 * storage, so a key made in Safari would lock the employee out of his own installed app: bind only when installed.
 */
export function mustInstallFirst(ua: string, standalone: boolean | undefined): boolean {
  return /iPhone|iPad|iPod/i.test(ua) && standalone !== true;
}
