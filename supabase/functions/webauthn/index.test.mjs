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
const db = { policy: "required", device: null, challenges: new Map(), tickets: [], calls: [], user: { id: EMP }, inactive: false,
  // phase 9 (fingerprint login) fake: same contract as the service_login_* SQL functions
  mustChange: false, loginChal: new Map(), fails: 0, links: [], linkError: false, audits: [] };
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
    if (fn.startsWith("service_login_")) {
      const L = db;
      const no = (m) => ({ data: null, error: { message: m } });
      if (!L.device || args.p_credential_id !== L.device.id) {
        if (fn === "service_login_take_challenge") return { data: null, error: null };
        return no("device_not_registered");
      }
      if (fn === "service_login_context") {
        if (L.inactiveLogin) return no("employee_inactive");
        if (L.fails >= 5) return no("too_many_attempts");
        if (L.mustChange) return no("password_required");
        if (L.policy !== "required") return no("biometric_off");
        return { data: { employee_id: EMP, company_id: "c1", email: "emp@example.test",
          credential: { credential_id: L.device.id, public_key_b64u: L.device.pk, sign_count: L.device.count, transports: L.device.transports } }, error: null };
      }
      if (fn === "service_login_put_challenge") {
        if (L.fails >= 5) return no("too_many_attempts");
        const id = randomUUID(); L.loginChal.set(id, { cred: args.p_credential_id, challenge: args.p_challenge }); return { data: id, error: null };
      }
      if (fn === "service_login_take_challenge") {
        const c = L.loginChal.get(args.p_challenge_id);
        if (!c || c.cred !== args.p_credential_id) return { data: null, error: null };
        L.loginChal.delete(args.p_challenge_id); return { data: c.challenge, error: null };
      }
      if (fn === "service_login_result") {
        if (L.fails >= 5) return no("too_many_attempts");
        let good = args.p_ok;
        if (good && (args.p_new_count ?? 0) > 0 && L.device.count > 0 && args.p_new_count <= L.device.count) good = false;
        if (!good) { L.fails++; return { data: { ok: false, error: "biometric_failed" }, error: null }; }
        L.device.count = Math.max(L.device.count, args.p_new_count ?? 0); L.fails = 0; L.audits.push("auth.biometric_login");
        return { data: { ok: true }, error: null };
      }
    }
    return { data: null, error: { message: "unknown " + fn } };
  },
  generateLink: async (role, a) => {
    db.calls.push({ role, fn: "generateLink" });
    if (role !== "service") return { data: null, error: { message: "not allowed" } };
    if (db.linkError) return { data: null, error: { message: "boom secret-detail" } };
    db.links.push(a); return { data: { properties: { hashed_token: "hash-" + db.links.length } }, error: null };
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
// ---- phase 9: fingerprint login (no session: only the public key of the project, like a logged-out phone)
const anon = "Bearer anon-key";
const cid = b64u(credId);
const lopt = (credential_id = cid) => call({ action: "login-options", credential_id }, anon);
const lver = (body) => call({ action: "login-verify", ...body }, anon);
const errOf = async (res) => (await res.json()).error;
const before = db.calls.length;
r = await lopt("no-such-device");
ok(r.status === 409 && (await errOf(r)) === "device_not_registered", "login: unknown device -> device_not_registered");
r = await call({ action: "login-options" }, anon);
ok(r.status === 400 && (await errOf(r)) === "invalid_input", "login: credential id is required");
r = await call({ action: "login-options", credential_id: "x".repeat(1025) }, anon);
ok(r.status === 400, "login: credential id too long");
r = await call({ action: "login-options", credential_id: 5 }, anon);
ok(r.status === 400, "login: credential id must be a string");

// happy path
r = await lopt();
const lo = await r.json();
ok(r.status === 200 && lo.options?.challenge && lo.options.allowCredentials[0].id === cid && lo.options.userVerification === "required" && /^[0-9a-f-]{36}$/.test(lo.challenge_id),
   "login: options carry a challenge, the device and userVerification=required", JSON.stringify(lo).slice(0, 160));
const goodAssertion = assert(lo.options.challenge);
r = await lver({ credential_id: cid, challenge_id: lo.challenge_id, response: goodAssertion });
const lv = await r.json();
ok(r.status === 200 && lv.token_hash === "hash-1" && Object.keys(lv).length === 1, "login: a valid fingerprint gives only a one-time token", JSON.stringify(lv));
ok(db.links.length === 1 && db.links[0].type === "magiclink" && db.links[0].email === "emp@example.test", "login: link made for the e-mail the DATABASE gave");
ok(db.audits.length === 1, "login: success recorded");
r = await lver({ credential_id: cid, challenge_id: lo.challenge_id, response: goodAssertion });
ok(r.status === 400 && (await errOf(r)) === "biometric_failed" && db.links.length === 1, "login: the same signature and challenge cannot be used twice");
ok(db.calls.slice(before).every((c) => c.fn !== "employee_webauthn_context"), "login: needs no session (the caller's token is never read)");

// forged signature (another key). The earlier refusals each counted as a failure; start clean for each case below.
db.fails = 0;
const other = generateKeyPairSync("ec", { namedCurve: "P-256" });
r = await lopt(); const lo2 = await r.json();
{
  const authData = head(0x05, ++count);
  const cd = Buffer.from(JSON.stringify({ type: "webauthn.get", challenge: lo2.options.challenge, origin: ORIGIN }));
  const forged = { id: cid, rawId: cid, type: "public-key", clientExtensionResults: {},
    response: { clientDataJSON: b64u(cd), authenticatorData: b64u(authData), signature: b64u(sign("sha256", Buffer.concat([authData, sha(cd)]), other.privateKey)) } };
  r = await lver({ credential_id: cid, challenge_id: lo2.challenge_id, response: forged });
  ok(r.status === 400 && (await errOf(r)) === "biometric_failed" && db.links.length === 1 && db.fails === 1, "login: signature from another key refused and counted", String(db.fails));
  db.fails = 0;
}
// challenge of someone else / wrong origin / wrong type
r = await lopt(); const lo3 = await r.json();
r = await lver({ credential_id: cid, challenge_id: lo3.challenge_id, response: assert("AAAA" + lo3.options.challenge.slice(4)) });
ok(r.status === 400 && db.links.length === 1, "login: signature over a different challenge refused");
db.fails = 0;
r = await lopt(); const lo4 = await r.json();
r = await lver({ credential_id: cid, challenge_id: randomUUID(), response: assert(lo4.options.challenge) });
ok(r.status === 400 && (await errOf(r)) === "biometric_failed" && db.links.length === 1, "login: unknown challenge id refused");
ok(db.fails === 0, "login: a missing challenge is NOT counted (nothing could have been verified; counting would let strangers lock someone out)", String(db.fails));
db.fails = 0;
r = await lver({ credential_id: "other-device", challenge_id: lo4.challenge_id, response: assert(lo4.options.challenge) });
ok(r.status === 409 && db.links.length === 1, "login: challenge cannot be used with another credential id");
r = await lver({ credential_id: cid, challenge_id: "not-a-uuid", response: goodAssertion });
ok(r.status === 400 && (await errOf(r)) === "invalid_input", "login: challenge id must be a uuid");
r = await lver({ credential_id: cid, challenge_id: lo4.challenge_id });
ok(r.status === 400 && (await errOf(r)) === "invalid_input", "login: response is required");
// counter that does not grow (copied key)
r = await lopt(); const lo5 = await r.json();
{
  const sig = assert(lo5.options.challenge);
  db.device.count = count + 10;   // the server has already seen a higher counter
  r = await lver({ credential_id: cid, challenge_id: lo5.challenge_id, response: sig });
  ok(r.status === 400 && (await errOf(r)) === "biometric_failed" && db.links.length === 1, "login: counter that does not grow refused, no link");
  db.device.count = count; db.fails = 0;
}
// state changed between the two steps
r = await lopt(); const lo6 = await r.json();
db.policy = "off";
r = await lver({ credential_id: cid, challenge_id: lo6.challenge_id, response: assert(lo6.options.challenge) });
ok(r.status === 403 && (await errOf(r)) === "biometric_off" && db.links.length === 1, "login: company switched fingerprint off -> refused, no link");
r = await lopt();
ok(r.status === 403 && (await errOf(r)) === "biometric_off", "login: options refused while the company has it off");
db.policy = "required";
db.mustChange = true;
r = await lopt();
ok(r.status === 403 && (await errOf(r)) === "password_required", "login: temporary password -> password_required");
db.mustChange = false;
db.inactiveLogin = true;
r = await lopt();
ok(r.status === 403 && (await errOf(r)) === "employee_inactive", "login: inactive employee/company -> employee_inactive (the phone must not forget its device)");
db.inactiveLogin = false;
// the link service fails: nothing leaks
db.fails = 0;
r = await lopt(); const lo7 = await r.json();
db.linkError = true;
r = await lver({ credential_id: cid, challenge_id: lo7.challenge_id, response: assert(lo7.options.challenge) });
const t7 = await r.text();
ok(r.status === 500 && JSON.parse(t7).error === "server_error" && !t7.includes("secret-detail"), "login: link failure -> server_error without details", t7);
db.linkError = false;
// lock after 5 failures
db.fails = 0;
for (let i = 0; i < 5; i++) {
  r = await lopt(); const lx = await r.json();
  await lver({ credential_id: cid, challenge_id: lx.challenge_id, response: assert("wrong-" + i) });
}
r = await lopt();
ok(r.status === 429 && (await errOf(r)) === "too_many_attempts", "login: locked after 5 failures");
const linksBefore = db.links.length;
r = await lver({ credential_id: cid, challenge_id: randomUUID(), response: goodAssertion });
ok(r.status === 429 && db.links.length === linksBefore, "login: locked -> no verification, no link");
db.fails = 0;
// only the service role makes links
ok(db.calls.filter((c) => c.fn === "generateLink").every((c) => c.role === "service"), "login: links only with the service key");
// the authenticated actions still need a real session
r = await call({ action: "punch-options" }, anon);
ok(r.status === 401, "punch-options still needs a session");
r = await call({ action: "register-options" }, anon);
ok(r.status === 401, "register-options still needs a session");

ok(db.calls.filter((c) => c.fn.startsWith("service_")).every((c) => c.role === "service")
   && db.calls.filter((c) => c.fn === "employee_webauthn_context").every((c) => c.role === "user"), "service RPCs only with the service key; context with the caller's token");

console.log(fails ? `FAILED ${fails}` : "ALL PASSED");
process.exit(fails ? 1 : 0);
