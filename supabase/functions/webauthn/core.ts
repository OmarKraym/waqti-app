// WebAuthn rules for Waqti: the relying party is the employee app's site, the phone's own lock (fingerprint, face or
// PIN) must be used (userVerification "required"), and only the phone's built-in authenticator is offered.
// Pure functions (no network, no database), so they can be tested in Node with a software authenticator.
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "./deps.ts";

export const RP = { id: "omarkraym.github.io", name: "وقتي", origin: "https://omarkraym.github.io" } as const;

const b64u = (b: Uint8Array): string => {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

export function registrationOptions(userId: string, userName: string, displayName: string) {
  return generateRegistrationOptions({
    rpName: RP.name,
    rpID: RP.id,
    userID: new TextEncoder().encode(userId),
    userName,
    userDisplayName: displayName,
    attestationType: "none",
    supportedAlgorithmIDs: [-7, -257],
    authenticatorSelection: { authenticatorAttachment: "platform", residentKey: "preferred", userVerification: "required" },
  });
}

// deno-lint-ignore no-explicit-any
export async function verifyRegistration(response: any, expectedChallenge: string) {
  const r = await verifyRegistrationResponse({
    response, expectedChallenge, expectedOrigin: RP.origin, expectedRPID: RP.id, requireUserVerification: true,
  });
  if (!r.verified || !r.registrationInfo) throw new Error("biometric_failed");
  const c = r.registrationInfo.credential;
  return { credentialId: c.id, publicKeyB64u: b64u(c.publicKey), counter: c.counter, transports: c.transports ?? [] };
}

export function authenticationOptions(credentialId: string, transports: string[]) {
  return generateAuthenticationOptions({
    rpID: RP.id,
    userVerification: "required",
    // deno-lint-ignore no-explicit-any
    allowCredentials: [{ id: credentialId, transports: transports as any }],
  });
}

export async function verifyAuthentication(
  // deno-lint-ignore no-explicit-any
  response: any,
  expectedChallenge: string,
  credential: { id: string; publicKey: Uint8Array; counter: number; transports: string[] },
) {
  const r = await verifyAuthenticationResponse({
    response, expectedChallenge, expectedOrigin: RP.origin, expectedRPID: RP.id, requireUserVerification: true,
    // deno-lint-ignore no-explicit-any
    credential: credential as any,
  });
  if (!r.verified) throw new Error("biometric_failed");
  return { newCounter: r.authenticationInfo.newCounter };
}
