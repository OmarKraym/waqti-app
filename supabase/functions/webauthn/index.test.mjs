// End-to-end test of index.ts with a fake Supabase client (same contract as the real RPCs) and a software authenticator.
// Run: node --experimental-strip-types index.test.mjs <harness dir>   (the harness holds core.ts, index.ts copies and
//      fake-supabase.mjs; see the run script)
import { createHash, generateKeyPairSync, sign, randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const dir = process.argv[2];
const require = createRequire(dir + "/core.ts");
const { encodeCBOR } = require("@levischuck/tiny-cbor");
let fails = 0;
const ok = (c, n, d = "") => { console.log((c ? "PASS " : "FAIL ") + n + (c ? "" : "  " + d)); if (!c) fails++; };
const b64u = (b) => Buffer.from(b).toString("base64url");
const sha = (b) => createHash("sha256").update(b).digest();
const RP_ID = "omarkraym.github.io", ORIGIN = "https://omarkraym.github.io";

// ---- fake database: what the real RPCs do, in memory
const EMP = "e0000001-0000-4000-8000-000000000000";
const db = { policy: "required", device: null, challenges: new Map(), tickets: [], calls: [], user: { id: EMP }, inactive: false };
globalThis.__fake = {
  getUser: (auth) => (auth === "Bearer good" ? { data: { user: db.user }, error: null } : { data: { user: null }, error: { message: "bad jwt" } }),
  rpc: async (role, fn, args) => {
    db.calls.push({ role, fn });
    if (fn === "employee_webauthn_context") {
      if (role !== "user") return { data: null, error: { message: "permission denied" } };
      if (db.inactive) return { data: null, error: { message: "employee_inactive" } };
      return { data: { employee_id: EMP, company_id: "c1", policy: db.policy, has_device: !!db.device, user_name: "001", display_name: "أحمد",
        credential: db.device && { credential_id: db.device.id, public_key_b64u: db.device.pk, sign_count: db.device.count, transports: db.device.transports } }, error: null };
    }
    if (role !== "service") return { data: null, error: { message: "permission denied" } };
    if (fn === "service_webauthn_put_challenge") { db.challenges.set(args.p_purpose, args.p_challenge); return { data: null, error: null }; }
    if (fn === "service_webauthn_take_challenge") { const c = db.challenges.get(args.p_purpose) ?? null; db.challenges.delete(args.p_purpose); return { data: c, error: null }; }
    if (fn === "service_webauthn_register") {
      if (db.device) return { data: null, error: { message: "device_already_registered" } };
      db.device = { id: args.p_credential_id, pk: args.p_public_key_b64u, count: args.p_sign_count, transports: args.p_transports, label: args.p_label };
      return { data: { ok: true }, error: null };
    }
    if (fn === "service_webauthn_issue_ticket") {
      if (!db.device || args.p_credential_id !== db.device.id) return { data: null, error: { message: "biometric_failed" } };
      db.device.count = args.p_new_count; db.tickets.push(args.p_request_id); return { data: { ok: true }, error: null };
    }
    return { data: null, error: { message: "unknown " + fn } };
  },
};
let handler;
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: "https://x.supabase.co", SUPABASE_ANON_KEY: "anon", SUPABASE_SERVICE_ROLE_KEY: "service" })[k] }, serve: (h) => { handler = h; } };
await import(pathToFileURL(dir + "/index.ts").href);

const call = (body, auth = "Bearer good", method = "POST") =>
  handler(new Request("https://f/webauthn", { method, headers: { Authorization: auth, "Content-Type": "application/json", "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)" }, body: method === "POST" ? JSON.stringify(body) : undefined }));

// ---- software authenticator
const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const jwk = publicKey.export({ format: "jwk" });
const credId = randomBytes(32);
let count = 0;
const head = (f, n) => Buffer.concat([sha(RP_ID), Buffer.from([f]), Buffer.from([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255])]);
const register = (challenge) => {
  const cose = encodeCBOR(new Map([[1, 2], [3, -7], [-1, 1], [-2, new Uint8Array(Buffer.from(jwk.x, "base64url"))], [-3, new Uint8Array(Buffer.from(jwk.y, "base64url"))]]));
  const authData = Buffer.concat([head(0x45, 0), Buffer.alloc(16), Buffer.from([0, 32]), credId, Buffer.from(cose)]);
  const cd = Buffer.from(JSON.stringify({ type: "webauthn.create", challenge, origin: ORIGIN }));
  return { id: b64u(credId), rawId: b64u(credId), type: "public-key", clientExtensionResults: {},
    response: { clientDataJSON: b64u(cd), attestationObject: b64u(encodeCBOR(new Map([["fmt", "none"], ["attStmt", new Map()], ["authData", new Uint8Array(authData)]]))), transports: ["internal"] } };
};
const assert = (challenge) => {
  const authData = head(0x05, ++count);
  const cd = Buffer.from(JSON.stringify({ type: "webauthn.get", challenge, origin: ORIGIN }));
  return { id: b64u(credId), rawId: b64u(credId), type: "public-key", clientExtensionResults: {},
    response: { clientDataJSON: b64u(cd), authenticatorData: b64u(authData), signature: b64u(sign("sha256", Buffer.concat([authData, sha(cd)]), privateKey)) } };
};

// ---- access
let r = await call({ action: "punch-options" }, "Bearer bad");
ok(r.status === 401, "no valid session: 401");
r = await call({}, "Bearer good", "GET");
ok(r.status === 405, "GET refused");
db.inactive = true;
r = await call({ action: "register-options" });
ok(r.status === 403 && (await r.json()).error === "employee_inactive", "inactive employee refused by the database");
db.inactive = false;
db.policy = "off";
r = await call({ action: "register-options" });
ok(r.status === 403 && (await r.json()).error === "forbidden", "policy off: no registration");
db.policy = "required";
r = await call({ action: "punch-options" });
ok(r.status === 409 && (await r.json()).error === "device_not_registered", "no device: punch options refused");
r = await call({ action: "nonsense" });
ok(r.status === 400 && (await r.json()).error === "invalid_input", "unknown action");

// ---- registration
r = await call({ action: "register-options" });
const ro = await r.json();
ok(r.status === 200 && ro.rp.id === RP_ID && db.challenges.get("register") === ro.challenge, "registration options + challenge stored", JSON.stringify(ro).slice(0, 120));
r = await call({ action: "register-verify", response: register(ro.challenge), label: "  " });
ok(r.status === 200 && db.device?.id === b64u(credId) && db.device.label === "iPhone", "device registered, label from the browser", JSON.stringify(db.device?.label));
r = await call({ action: "register-verify", response: register(ro.challenge) });
ok(r.status === 400 && (await r.json()).error === "biometric_failed", "challenge used once");
r = await call({ action: "register-options" });
ok(r.status === 409 && (await r.json()).error === "device_already_registered", "second device refused");

// ---- punch
r = await call({ action: "punch-options" });
const po = await r.json();
ok(r.status === 200 && po.allowCredentials[0].id === b64u(credId), "punch options for the device");
const req = randomUUID();
r = await call({ action: "punch-verify", response: assert(po.challenge), request_id: "not-a-uuid" });
ok(r.status === 400 && (await r.json()).error === "invalid_input", "request id must be a uuid");
ok(db.challenges.has("punch"), "a bad request does not use up the challenge");
const signed = assert(po.challenge);
r = await call({ action: "punch-verify", response: signed, request_id: req });
ok(r.status === 200 && db.tickets.includes(req) && db.device.count === count, "ticket issued for the punch", JSON.stringify(await r.json()));
r = await call({ action: "punch-verify", response: signed, request_id: randomUUID() });
ok(r.status === 400 && (await r.json()).error === "biometric_failed" && db.tickets.length === 1, "replayed fingerprint refused");
ok(db.calls.filter((c) => c.fn.startsWith("service_")).every((c) => c.role === "service")
   && db.calls.filter((c) => c.fn === "employee_webauthn_context").every((c) => c.role === "user"), "service RPCs only with the service key; context with the caller's token");

console.log(fails ? `FAILED ${fails}` : "ALL PASSED");
process.exit(fails ? 1 : 0);
