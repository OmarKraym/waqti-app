// webauthn: fingerprint (WebAuthn) for the employee app.
//   register-options / register-verify : binds ONE device to the employee (company policy must be "required")
//   punch-options / punch-verify       : checks a fingerprint signature and issues a single-use ticket for one punch
//   set-login                          : (phase 10) the employee turns fingerprint sign-in on (needs a fresh fingerprint) or off
//   login-options / login-verify       : (phase 9) sign in with the registered phone's fingerprint. These two run WITHOUT a
//                                        session: who may sign in is decided only by the database (service_login_*), the
//                                        challenge is single use and bound to the credential, and 5 failures lock it.
//                                        On success the function returns a one-time token for auth.verifyOtp (no password).
// The caller is read from their own token, and what they may do from the DATABASE (employee_webauthn_context, which
// refuses inactive employees and temporary passwords). Devices, challenges and tickets are written only through
// service-role functions. Nothing secret (challenges, keys, signatures) is logged.
import { createClient } from "npm:@supabase/supabase-js@2";
import { authenticationOptions, registrationOptions, RP, verifyAuthentication, verifyRegistration } from "./core.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": RP.origin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACCOUNT_ERRORS = new Set(["employee_inactive", "must_change_password", "not_authenticated"]);

function fromB64u(s: string): Uint8Array {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** A short name for the device from the browser, when the app sends none (shown to the admin). */
function deviceLabel(sent: unknown, ua: string): string {
  const s = typeof sent === "string" ? sent.trim() : "";
  if (s) return s.slice(0, 120);
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/Windows/.test(ua)) return "Windows";
  if (/Mac OS X/.test(ua)) return "Mac";
  return "جهاز";
}

type Context = {
  employee_id: string;
  policy: "off" | "required";
  has_device: boolean;
  user_name: string;
  display_name: string;
  credential: { credential_id: string; public_key_b64u: string; sign_count: number; transports: string[] } | null;
};


const LOGIN_ERRORS: Record<string, number> = {
  device_not_registered: 409, too_many_attempts: 429, password_required: 403, biometric_off: 403, employee_inactive: 403, login_disabled: 403,
};

/** Maps a service_login_* error to the answer for the phone. Anything unexpected is a plain server_error (no details). */
function loginError(message: string | undefined): Response {
  const m = message ?? "";
  if (m in LOGIN_ERRORS) return json({ error: m }, LOGIN_ERRORS[m]);
  console.error("login rpc failed");
  return json({ error: "server_error" }, 500);
}

// deno-lint-ignore no-explicit-any
async function handleLogin(body: Record<string, any>, admin: any): Promise<Response> {
  const credentialId = body.credential_id;
  if (typeof credentialId !== "string" || credentialId.length < 1 || credentialId.length > 1024) return json({ error: "invalid_input" }, 400);

  if (body.action === "login-options") {
    const { data: ctx, error } = await admin.rpc("service_login_context", { p_credential_id: credentialId });
    if (error || !ctx) return loginError(error?.message);
    const options = await authenticationOptions(credentialId, (ctx as Context).credential?.transports ?? []);
    const put = await admin.rpc("service_login_put_challenge", { p_credential_id: credentialId, p_challenge: options.challenge });
    if (put.error || !put.data) return loginError(put.error?.message);
    return json({ options, challenge_id: put.data });
  }

  // login-verify
  const challengeId = body.challenge_id;
  if (typeof challengeId !== "string" || !UUID_RE.test(challengeId)) return json({ error: "invalid_input" }, 400);
  if (typeof body.response !== "object" || body.response === null) return json({ error: "invalid_input" }, 400);

  const { data: ctxData, error: ctxError } = await admin.rpc("service_login_context", { p_credential_id: credentialId });
  if (ctxError || !ctxData) return loginError(ctxError?.message);
  const ctx = ctxData as Context & { email: string };

  // A signature that does not verify is counted against the credential (5 in 15 minutes lock it).
  const refuse = async (): Promise<Response> => {
    const r = await admin.rpc("service_login_result", { p_credential_id: credentialId, p_ok: false, p_new_count: null });
    if (r.error) return loginError(r.error.message);
    return json({ error: "biometric_failed" }, 400);
  };

  const { data: challenge } = await admin.rpc("service_login_take_challenge", { p_challenge_id: challengeId, p_credential_id: credentialId });
  // No challenge (unknown, used, expired, or made for another credential): nothing could have been verified, so it is
  // refused but NOT counted. Counting it would let anyone who knows a credential id lock that employee out.
  if (!challenge) return json({ error: "biometric_failed" }, 400);
  let result;
  try {
    result = await verifyAuthentication(body.response, challenge as string, {
      id: ctx.credential!.credential_id,
      publicKey: fromB64u(ctx.credential!.public_key_b64u),
      counter: Number(ctx.credential!.sign_count) || 0,
      transports: ctx.credential!.transports ?? [],
    });
  } catch {
    return await refuse();
  }
  // The link is made first and handed out only if the database accepts the result (counter, lock, audit).
  const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email: ctx.email });
  const token = link?.properties?.hashed_token;
  if (linkError || typeof token !== "string") {
    console.error("login link failed");
    return json({ error: "server_error" }, 500);
  }
  const done = await admin.rpc("service_login_result", { p_credential_id: credentialId, p_ok: true, p_new_count: result.newCounter });
  if (done.error) return loginError(done.error.message);
  if (!done.data?.ok) return json({ error: "biometric_failed" }, 400);
  return json({ token_hash: token });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

  // Fingerprint login has no session yet: peek at the action first (a bad body falls through to the normal path below).
  let peek: Record<string, unknown> | null = null;
  try {
    peek = await req.clone().json();
  } catch {
    peek = null;
  }
  if (peek && (peek.action === "login-options" || peek.action === "login-verify")) {
    return await handleLogin(peek, createClient(url, serviceKey, noSession));
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { ...noSession, global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: "not_authenticated" }, 401);

  const { data: ctxData, error: ctxError } = await userClient.rpc("employee_webauthn_context");
  if (ctxError || !ctxData) {
    const code = ctxError && ACCOUNT_ERRORS.has(ctxError.message) ? ctxError.message : "forbidden";
    return json({ error: code }, 403);
  }
  const ctx = ctxData as Context;
  const admin = createClient(url, serviceKey, noSession);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_input" }, 400);
  }

  switch (body.action) {
    case "register-options": {
      if (ctx.policy !== "required") return json({ error: "forbidden" }, 403);
      if (ctx.has_device) return json({ error: "device_already_registered" }, 409);
      const options = await registrationOptions(ctx.employee_id, ctx.user_name, ctx.display_name);
      const { error } = await admin.rpc("service_webauthn_put_challenge", { p_employee: ctx.employee_id, p_purpose: "register", p_challenge: options.challenge });
      if (error) return json({ error: "server_error" }, 500);
      return json(options);
    }

    case "register-verify": {
      if (ctx.policy !== "required") return json({ error: "forbidden" }, 403);
      const { data: challenge } = await admin.rpc("service_webauthn_take_challenge", { p_employee: ctx.employee_id, p_purpose: "register" });
      if (!challenge) return json({ error: "biometric_failed" }, 400);
      let saved;
      try {
        saved = await verifyRegistration(body.response, challenge as string);
      } catch {
        return json({ error: "biometric_failed" }, 400);
      }
      const { error } = await admin.rpc("service_webauthn_register", {
        p_employee: ctx.employee_id,
        p_credential_id: saved.credentialId,
        p_public_key_b64u: saved.publicKeyB64u,
        p_sign_count: saved.counter,
        p_transports: saved.transports,
        p_label: deviceLabel(body.label, req.headers.get("User-Agent") ?? ""),
      });
      if (error) {
        if (error.message === "device_already_registered") return json({ error: "device_already_registered" }, 409);
        console.error("register failed");
        return json({ error: "server_error" }, 500);
      }
      return json({ ok: true });
    }

    case "punch-options": {
      if (!ctx.credential) return json({ error: "device_not_registered" }, 409);
      const options = await authenticationOptions(ctx.credential.credential_id, ctx.credential.transports ?? []);
      const { error } = await admin.rpc("service_webauthn_put_challenge", { p_employee: ctx.employee_id, p_purpose: "punch", p_challenge: options.challenge });
      if (error) return json({ error: "server_error" }, 500);
      return json(options);
    }

    case "punch-verify": {
      if (!ctx.credential) return json({ error: "device_not_registered" }, 409);
      const requestId = typeof body.request_id === "string" ? body.request_id : "";
      if (!UUID_RE.test(requestId)) return json({ error: "invalid_input" }, 400);
      const { data: challenge } = await admin.rpc("service_webauthn_take_challenge", { p_employee: ctx.employee_id, p_purpose: "punch" });
      if (!challenge) return json({ error: "biometric_failed" }, 400);
      let result;
      try {
        result = await verifyAuthentication(body.response, challenge as string, {
          id: ctx.credential.credential_id,
          publicKey: fromB64u(ctx.credential.public_key_b64u),
          counter: Number(ctx.credential.sign_count) || 0,
          transports: ctx.credential.transports ?? [],
        });
      } catch {
        return json({ error: "biometric_failed" }, 400);
      }
      const { error } = await admin.rpc("service_webauthn_issue_ticket", {
        p_employee: ctx.employee_id, p_credential_id: ctx.credential.credential_id, p_new_count: result.newCounter, p_request_id: requestId,
      });
      if (error) return json({ error: "biometric_failed" }, 400);
      return json({ ok: true });
    }

    case "set-login": {
      // Turn fingerprint SIGN-IN on or off (phase 10). Off needs nothing (it only closes a door). On needs a fresh
      // fingerprint over a challenge from punch-options (single use), like a punch does; the company rule must be on.
      const enabled = body.enabled;
      if (typeof enabled !== "boolean") return json({ error: "invalid_input" }, 400);
      if (!ctx.credential) return json({ error: "device_not_registered" }, 409);
      let newCount: number | null = null;
      if (enabled) {
        if (ctx.policy !== "required") return json({ error: "forbidden" }, 403);
        if (typeof body.response !== "object" || body.response === null) return json({ error: "invalid_input" }, 400);
        const { data: challenge } = await admin.rpc("service_webauthn_take_challenge", { p_employee: ctx.employee_id, p_purpose: "punch" });
        if (!challenge) return json({ error: "biometric_failed" }, 400);
        try {
          const result = await verifyAuthentication(body.response, challenge as string, {
            id: ctx.credential.credential_id,
            publicKey: fromB64u(ctx.credential.public_key_b64u),
            counter: Number(ctx.credential.sign_count) || 0,
            transports: ctx.credential.transports ?? [],
          });
          newCount = result.newCounter;
        } catch {
          return json({ error: "biometric_failed" }, 400);
        }
      }
      const { data, error } = await admin.rpc("service_webauthn_set_login", { p_employee: ctx.employee_id, p_enabled: enabled, p_new_count: newCount });
      if (error) {
        if (error.message === "biometric_failed") return json({ error: "biometric_failed" }, 400);
        if (error.message === "device_not_registered") return json({ error: "device_not_registered" }, 409);
        console.error("set-login failed");
        return json({ error: "server_error" }, 500);
      }
      return json({ login_enabled: data?.login_enabled === true });
    }

    default:
      return json({ error: "invalid_input" }, 400);
  }
});
