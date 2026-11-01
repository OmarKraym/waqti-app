// Copied from the production Edge Function on 2026-11-01 (security audit SEC-011), unchanged.
// reset-employee-password v2 (multi-company): a company admin sets a NEW temporary password for an
// employee of THEIR OWN company.
// Flow: verify caller -> caller must be an active company admin (from the DATABASE) -> refuse self ->
// target must be a member of the SAME company and not an admin -> new random temporary password ->
// end all old sessions -> audit log. The password is returned once and never stored or logged.
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

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

function randomInt(max: number): number {
  const limit = Math.floor(256 / max) * max;
  const buf = new Uint8Array(1);
  while (true) {
    crypto.getRandomValues(buf);
    if (buf[0] < limit) return buf[0] % max;
  }
}

function generateTempPassword(length = 14): string {
  while (true) {
    let p = "";
    for (let i = 0; i < length; i++) p += ALPHABET[randomInt(ALPHABET.length)];
    if (/[a-z]/.test(p) && /[A-Z]/.test(p) && /[0-9]/.test(p)) return p;
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

  // 1) Caller must be an active company admin (database check, not the JWT).
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { ...noSession, global: { headers: { Authorization: authHeader } } });
  const { data: callerData, error: callerError } = await userClient.auth.getUser();
  if (callerError || !callerData?.user) return json({ error: "not_authenticated" }, 401);
  const caller = callerData.user;

  const { data: ctx, error: ctxError } = await userClient.rpc("my_admin_context");
  if (ctxError || !ctx?.is_company_admin || !ctx?.company_id) return json({ error: "forbidden" }, 403);
  const companyId: string = ctx.company_id;

  // 2) Input
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const employeeId = typeof body.employee_id === "string" ? body.employee_id : "";
  const mustChangePassword = body.must_change_password === true;
  if (!UUID_RE.test(employeeId)) return json({ error: "invalid_employee_id" }, 400);
  if (employeeId === caller.id) return json({ error: "cannot_reset_self" }, 400);

  // 3) Target must belong to the SAME company. Another company's user looks exactly like "not found".
  const admin = createClient(url, serviceKey, noSession);
  const { data: member, error: memberError } = await admin
    .from("company_members").select("company_id, role").eq("user_id", employeeId).maybeSingle();
  if (memberError) {
    console.error("membership lookup failed", memberError.message);
    return json({ error: "reset_failed" }, 500);
  }
  if (!member || member.company_id !== companyId) return json({ error: "employee_not_found" }, 404);
  if (member.role === "company_admin") return json({ error: "cannot_reset_manager" }, 403);

  const { data: targetData, error: targetError } = await admin.auth.admin.getUserById(employeeId);
  if (targetError || !targetData?.user) return json({ error: "employee_not_found" }, 404);
  const target = targetData.user;
  if (target.app_metadata?.role === "manager") return json({ error: "cannot_reset_manager" }, 403);

  // 4) New temporary password (other app_metadata is kept)
  const tempPassword = generateTempPassword();
  const { error: updateError } = await admin.auth.admin.updateUserById(target.id, {
    password: tempPassword,
    app_metadata: { ...target.app_metadata, must_change_password: mustChangePassword },
  });
  if (updateError) {
    console.error("reset failed", (updateError as { code?: string }).code, updateError.message);
    return json({ error: "reset_failed" }, 500);
  }

  // 5) End old sessions on all devices (reported if it fails: the password is already changed)
  let sessionsRevoked = true;
  const { error: revokeError } = await admin.rpc("service_revoke_user_sessions", { p_user_id: target.id });
  if (revokeError) {
    sessionsRevoked = false;
    console.error("session revoke failed", revokeError.message);
  }

  // 6) Audit (ids only, never the password)
  await admin.rpc("service_audit_write", {
    p_company_id: companyId,
    p_actor_id: caller.id,
    p_action: "account.reset_password",
    p_target_type: "employee",
    p_target_id: target.id,
    p_details: { must_change_password: mustChangePassword, sessions_revoked: sessionsRevoked },
  });

  return json({
    user_id: target.id,
    email: target.email ?? null,
    temporary_password: tempPassword,
    must_change_password: mustChangePassword,
    sessions_revoked: sessionsRevoked,
  });
});
