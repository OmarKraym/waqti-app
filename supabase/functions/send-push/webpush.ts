// Web Push (RFC 8030) with message encryption (RFC 8291, aes128gcm) and VAPID (RFC 8292).
// Only Web Crypto + fetch: runs the same in Supabase Edge Functions (Deno) and in Node 22 (tests).

const enc = new TextEncoder();

export function b64u(data: ArrayBuffer | Uint8Array): string {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64u(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8));
}

/** Encrypts a payload for one subscription (RFC 8291, single aes128gcm record). */
export async function encryptPayload(payload: Uint8Array, p256dh: string, auth: string, salt?: Uint8Array): Promise<Uint8Array> {
  const uaPublic = fromB64u(p256dh);
  const authSecret = fromB64u(auth);
  if (uaPublic.length !== 65 || authSecret.length !== 16) throw new Error("bad_subscription_keys");
  const local = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"])) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", local.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, local.privateKey, 256));

  const ikm = await hkdf(authSecret, ecdhSecret, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const s = salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(s, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(s, ikm, enc.encode("Content-Encoding: nonce\0"), 12);

  const record = concat(payload, new Uint8Array([2])); // 0x02 = last (and only) record, no padding
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, record));

  const rs = 4096;
  const header = new Uint8Array(16 + 4 + 1 + asPublic.length);
  header.set(s, 0);
  new DataView(header.buffer).setUint32(16, rs);
  header[20] = asPublic.length;
  header.set(asPublic, 21);
  const out = concat(header, cipher);
  if (out.length > 4096) throw new Error("payload_too_large"); // push services accept at most 4096 bytes
  return out;
}

export interface Vapid {
  /** Uncompressed P-256 public key (65 bytes), base64url: the same value the app subscribes with. */
  publicKey: string;
  privateKey: CryptoKey;
  /** mailto: or https: contact for the push service. */
  subject: string;
}

/** VAPID keys from a private JWK (kty EC, crv P-256, x, y, d). */
export async function vapidFromJwk(jwk: JsonWebKey, subject: string): Promise<Vapid> {
  const privateKey = await crypto.subtle.importKey("jwk", { ...jwk, key_ops: ["sign"], ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const publicKey = b64u(concat(new Uint8Array([4]), fromB64u(jwk.x!), fromB64u(jwk.y!)));
  return { publicKey, privateKey, subject };
}

export async function vapidHeader(endpoint: string, v: Vapid, nowSec = Math.floor(Date.now() / 1000)): Promise<string> {
  const aud = new URL(endpoint).origin;
  const head = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = b64u(enc.encode(JSON.stringify({ aud, exp: nowSec + 12 * 3600, sub: v.subject })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, v.privateKey, enc.encode(`${head}.${body}`));
  return `vapid t=${head}.${body}.${b64u(sig)}, k=${v.publicKey}`;
}

export interface PushSubscriptionKeys {
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** Sends one push. Returns the HTTP status (201 = accepted; 404/410 = subscription gone). */
export async function sendPush(
  sub: PushSubscriptionKeys,
  payload: unknown,
  v: Vapid,
  opts: { ttl?: number; urgency?: "very-low" | "low" | "normal" | "high"; topic?: string } = {},
  fetchFn: typeof fetch = fetch,
): Promise<{ status: number; body: string }> {
  const body = await encryptPayload(enc.encode(JSON.stringify(payload)), sub.p256dh, sub.auth);
  const headers: Record<string, string> = {
    "Content-Encoding": "aes128gcm",
    "Content-Type": "application/octet-stream",
    TTL: String(opts.ttl ?? 3600),
    Urgency: opts.urgency ?? "high",
    Authorization: await vapidHeader(sub.endpoint, v),
  };
  if (opts.topic) headers.Topic = opts.topic;
  const res = await fetchFn(sub.endpoint, { method: "POST", headers, body });
  return { status: res.status, body: res.status >= 400 ? (await res.text()).slice(0, 300) : "" };
}
