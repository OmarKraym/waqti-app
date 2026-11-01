// Copied from the production Edge Function on 2026-11-01 (security audit SEC-011), unchanged.
// change-password: completes the FIRST-LOGIN password change of an employee.
// Why an Edge Function: the flag `must_change_password` lives in app_metadata, which users cannot edit.
// Only the server (service role) can clear it. The function:
//   1) verifies the caller's token, 2) works only while the flag is true, 3) checks the password rules,
//   4) rejects the same password as the temporary one, 5) sets the new password AND clears the flag.
// After success the app must call auth.refreshSession() to get a token/user with the flag cleared.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

type Violation = "password_too_short" | "password_too_long" | "password_too_weak";

// Same rules as the Flutter screen. Length is measured in characters; bcrypt (used by Supabase Auth) ignores
// bytes after 72, so the upper limit is checked in bytes.
function checkPassword(p: string): Violation | null {
  if ([...p].length < 8) return "password_too_short";
  if (new TextEncoder().encode(p).length > 72) return "password_too_long";
  if (!/\p{L}/u.test(p) || !/\p{N}/u.test(p)) return "password_too_weak";
  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

  // 1) Who is calling?
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { ...noSession, global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: "not_authenticated" }, 401);
  const user = userData.user;

  // 2) Only for the forced first-login change.
  if (user.app_metadata?.must_change_password !== true) return json({ error: "not_required" }, 409);

  // 3) Password rules.
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const newPassword = typeof body.new_password === "string" ? body.new_password : "";
  const violation = checkPassword(newPassword);
  if (violation) return json({ error: violation }, 400);

  // 4) The new password must differ from the current (temporary) one:
  //    if signing in with it works, it is the same password.
  if (user.email) {
    const probe = createClient(url, anonKey, noSession);
    const { data: probeData } = await probe.auth.signInWithPassword({ email: user.email, password: newPassword });
    if (probeData?.session) return json({ error: "same_password" }, 400);
  }

  // 5) Set the password and clear the flag. The existing app_metadata (role, provider) is kept.
  const admin = createClient(url, serviceKey, noSession);
  const { error: updateError } = await admin.auth.admin.updateUserById(user.id, {
    password: newPassword,
    app_metadata: { ...user.app_metadata, must_change_password: false },
  });

  if (updateError) {
    const code = (updateError as { code?: string }).code;
    if (code === "weak_password") return json({ error: "password_too_weak" }, 400);
    if (code === "same_password") return json({ error: "same_password" }, 400);
    console.error("password update failed", code, updateError.message);
    return json({ error: "change_failed" }, 500);
  }

  return json({ ok: true });
});
