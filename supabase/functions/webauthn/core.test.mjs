// Tests for core.ts with a software authenticator (P-256, "none" attestation).
// Run: node --experimental-strip-types core.test.mjs <path to a copy of core.ts whose "./deps.ts" import points to
//      "@simplewebauthn/server"> — needs @simplewebauthn/server@13.2.3 installed next to that copy.
import { createHash, generateKeyPairSync, sign, randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const core = await import(pathToFileURL(process.argv[2]).href);
const require = createRequire(process.argv[2]);
// CBOR from the library's own dependency, so the encoding is exactly what it decodes (Maps with integer keys)
const { encodeCBOR } = require("@levischuck/tiny-cbor");
const encode = (v) => Buffer.from(encodeCBOR(v instanceof Map ? v : new Map(Object.entries(v))));

let fails = 0;
const ok = (c, n, d = "") => { console.log((c ? "PASS " : "FAIL ") + n + (c ? "" : "  " + d)); if (!c) fails++; };
const b64u = (b) => Buffer.from(b).toString("base64url");
const sha = (b) => createHash("sha256").update(b).digest();
const RP_ID = "omarkraym.github.io";
const ORIGIN = "https://omarkraym.github.io";

function authenticator() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  const credId = randomBytes(32);
  let count = 0;
  const flags = (uv) => 0x01 | (uv ? 0x04 : 0);
  const head = (f, n) => Buffer.concat([sha(RP_ID), Buffer.from([f]), Buffer.from([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255])]);
  return {
    credId,
    register(challenge, { origin = ORIGIN, uv = true } = {}) {
      const cose = encode(new Map([[1, 2], [3, -7], [-1, 1], [-2, new Uint8Array(Buffer.from(jwk.x, "base64url"))], [-3, new Uint8Array(Buffer.from(jwk.y, "base64url"))]]));
      const authData = Buffer.concat([head(flags(uv) | 0x40, 0), Buffer.alloc(16), Buffer.from([0, credId.length]), credId, cose]);
      const clientData = Buffer.from(JSON.stringify({ type: "webauthn.create", challenge, origin, crossOrigin: false }));
      return { id: b64u(credId), rawId: b64u(credId), type: "public-key", clientExtensionResults: {}, authenticatorAttachment: "platform",
        response: { clientDataJSON: b64u(clientData), attestationObject: b64u(encode(new Map([["fmt", "none"], ["attStmt", new Map()], ["authData", new Uint8Array(authData)]]))), transports: ["internal"] } };
    },
    assert(challenge, { origin = ORIGIN, uv = true, key = privateKey, counter } = {}) {
      count = counter ?? count + 1;
      const authData = head(flags(uv), count);
      const clientData = Buffer.from(JSON.stringify({ type: "webauthn.get", challenge, origin, crossOrigin: false }));
      const signature = sign("sha256", Buffer.concat([authData, sha(clientData)]), key);
      return { id: b64u(credId), rawId: b64u(credId), type: "public-key", clientExtensionResults: {}, authenticatorAttachment: "platform",
        response: { clientDataJSON: b64u(clientData), authenticatorData: b64u(authData), signature: b64u(signature) } };
    },
  };
}

const rejects = async (p) => { try { await p; return false; } catch { return true; } };

// ---- registration
ok(core.RP.id === RP_ID && core.RP.origin === ORIGIN, "RP values pinned");
const reg = await core.registrationOptions("e0000001-0000-4000-8000-000000000000", "001", "أحمد سالم");
ok(reg.rp.id === RP_ID && reg.authenticatorSelection.userVerification === "required"
   && reg.authenticatorSelection.authenticatorAttachment === "platform" && reg.attestation === "none", "registration options", JSON.stringify(reg.authenticatorSelection));
const dev = authenticator();
const saved = await core.verifyRegistration(dev.register(reg.challenge), reg.challenge);
ok(saved.credentialId === b64u(dev.credId) && typeof saved.publicKeyB64u === "string" && saved.counter === 0
   && saved.transports.includes("internal"), "registration verified", JSON.stringify({ ...saved, publicKeyB64u: "…" }));
ok(await rejects(core.verifyRegistration(authenticator().register(reg.challenge, { origin: "https://evil.example" }), reg.challenge)), "wrong origin refused");
ok(await rejects(core.verifyRegistration(authenticator().register("b3RoZXItY2hhbGxlbmdl"), reg.challenge)), "wrong challenge refused");
ok(await rejects(core.verifyRegistration(authenticator().register(reg.challenge, { uv: false }), reg.challenge)), "no user verification refused");

// ---- punch
const credential = { id: saved.credentialId, publicKey: Buffer.from(saved.publicKeyB64u, "base64url"), counter: 0, transports: saved.transports };
const auth = await core.authenticationOptions(saved.credentialId, saved.transports);
ok(auth.rpId === RP_ID && auth.userVerification === "required" && auth.allowCredentials.length === 1
   && auth.allowCredentials[0].id === saved.credentialId, "punch options limited to the device", JSON.stringify(auth.allowCredentials));
const r1 = await core.verifyAuthentication(dev.assert(auth.challenge), auth.challenge, credential);
ok(r1.newCounter === 1, "fingerprint verified, new counter returned", JSON.stringify(r1));
ok(await rejects(core.verifyAuthentication(dev.assert(auth.challenge, { origin: "https://evil.example" }), auth.challenge, credential)), "punch: wrong origin refused");
ok(await rejects(core.verifyAuthentication(dev.assert("b3RoZXI"), auth.challenge, credential)), "punch: wrong challenge refused");
ok(await rejects(core.verifyAuthentication(dev.assert(auth.challenge, { uv: false }), auth.challenge, credential)), "punch: no user verification refused");
const other = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
ok(await rejects(core.verifyAuthentication(dev.assert(auth.challenge, { key: other }), auth.challenge, credential)), "signature from another key refused");
ok(await rejects(core.verifyAuthentication(dev.assert(auth.challenge, { counter: 1 }), auth.challenge, { ...credential, counter: 5 })), "counter going back refused");

console.log(fails ? `FAILED ${fails}` : "ALL PASSED");
process.exit(fails ? 1 : 0);
