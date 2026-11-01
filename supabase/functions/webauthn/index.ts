// webauthn: fingerprint (WebAuthn) for the employee app.
//   register-options / register-verify : binds ONE device to the employee (company policy must be "required")
//   punch-options / punch-verify       : checks a fingerprint signature and issues a single-use ticket for one punch
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

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

    default:
      return json({ error: "invalid_input" }, 400);
  }
});
