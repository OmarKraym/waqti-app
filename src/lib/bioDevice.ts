// The phone remembers which fingerprint (WebAuthn credential) belongs to it, so the sign-in screen can offer
// "sign in with fingerprint" after sign-out. It is only the credential's public id, not a secret: without the
// fingerprint it opens nothing, and the server decides everything (who, whether allowed, whether the phone is still
// registered). Nothing here ever throws: storage can be blocked, and the password form always works.
const KEY = "waqti-bio-device";

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

function defaultStore(): Store | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

// WebAuthn credential ids are base64url text.
const VALID = /^[A-Za-z0-9_-]{1,1024}$/;

export function readDeviceHint(store: Store | null = defaultStore()): string | null {
  try {
    const v = store?.getItem(KEY) ?? null;
    return v !== null && VALID.test(v) ? v : null;
  } catch {
    return null;
  }
}

export function saveDeviceHint(credentialId: string, store: Store | null = defaultStore()): void {
  try {
    if (VALID.test(credentialId)) store?.setItem(KEY, credentialId);
  } catch {
    /* blocked storage: the password form still works */
  }
}

export function clearDeviceHint(store: Store | null = defaultStore()): void {
  try {
    store?.removeItem(KEY);
  } catch {
    /* ignore */
  }
}
