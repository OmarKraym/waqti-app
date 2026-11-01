// Copied from the production Edge Function on 2026-11-01 (security audit SEC-011), unchanged.
// create-employee v3 (multi-company): creates an employee account in the CALLER's company.
// Flow: verify caller token -> read caller context from the DATABASE (my_admin_context, not the JWT)
// -> company admin: creates employees of their own company
//    platform admin: may also create the first company admin of another company (body.company_id + company_role)
// -> check the employee code is free IN THAT COMPANY -> create the auth user with app_metadata.company_id
//    (a DB trigger creates the employees + company_members rows) -> save the HR profile with the caller's token
// -> on any failure, delete the new account. Every success is written to the audit log.
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
  const limit = Math.floor(256 / max) * max; // rejection sampling: no modulo bias
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

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PROFILE_ERRORS = new Set([
  "invalid_name", "invalid_employee_number", "invalid_department", "invalid_job_title", "invalid_gender",
  "invalid_dates", "invalid_work_location", "invalid_salary", "invalid_components", "invalid_schedule",
  "invalid_leave", "maternity_female_only", "employee_number_exists", "invalid_input", "forbidden",
]);

type AdminContext = {
  user_id: string | null;
  company_id: string | null;
  is_company_admin: boolean;
  is_platform_admin: boolean;
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

  // 1) Who is calling, and what may they do? (from the database, not from the JWT)
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(url, anonKey, { ...noSession, global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: "not_authenticated" }, 401);

  const { data: ctxData, error: ctxError } = await userClient.rpc("my_admin_context");
  if (ctxError || !ctxData) return json({ error: "forbidden" }, 403);
  const ctx = ctxData as AdminContext;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  // 2) Target company and role
  const requestedCompany = typeof body.company_id === "string" ? body.company_id : null;
  const companyRole = body.company_role === "company_admin" ? "company_admin" : "employee";
  let companyId: string;
  if (requestedCompany && requestedCompany !== ctx.company_id) {
    // Only the platform admin may create an account in another company, and only its admin.
    if (!ctx.is_platform_admin) return json({ error: "forbidden" }, 403);
    if (!UUID_RE.test(requestedCompany)) return json({ error: "invalid_company" }, 400);
    companyId = requestedCompany;
  } else {
    if (!ctx.is_company_admin || !ctx.company_id) return json({ error: "forbidden" }, 403);
    // Creating another admin is a platform decision (least privilege).
    if (companyRole === "company_admin" && !ctx.is_platform_admin) return json({ error: "forbidden" }, 403);
    companyId = ctx.company_id;
  }
  const saveProfile = companyId === ctx.company_id && ctx.is_company_admin;

  // 3) Account fields (HR fields are validated by the database function)
  const email = String(body.email ?? "").trim().toLowerCase();
  const fullName = String(body.full_name ?? "").trim();
  const department = String(body.department ?? "").trim();
  const employeeNumber = String(body.employee_number ?? "").trim();
  const geofenceRequired = body.geofence_required === false ? false : true;
  const mustChangePassword = body.must_change_password === true;

  if (!EMAIL_RE.test(email) || email.length > 254) return json({ error: "invalid_email" }, 400);
  if (fullName.length < 2 || fullName.length > 100) return json({ error: "invalid_name" }, 400);
  if (saveProfile && (employeeNumber.length < 1 || employeeNumber.length > 30)) {
    return json({ error: "invalid_employee_number" }, 400);
  }

  const admin = createClient(url, serviceKey, noSession);

  const { data: company, error: companyError } = await admin
    .from("companies").select("id, is_active").eq("id", companyId).maybeSingle();
  if (companyError) return json({ error: "create_failed" }, 500);
  if (!company || !company.is_active) return json({ error: "invalid_company" }, 400);

  // 4) Fast check: the employee code must be free in THIS company (the database also enforces it)
  if (employeeNumber) {
    const { data: existing, error: lookupError } = await admin
      .from("employees").select("id").eq("company_id", companyId).eq("employee_number", employeeNumber).maybeSingle();
    if (lookupError) {
      console.error("code lookup failed", lookupError.message);
      return json({ error: "create_failed" }, 500);
    }
    if (existing) return json({ error: "employee_number_exists" }, 409);
  }

  // 5) Create the account. company_id in app_metadata = which company the DB trigger joins it to.
  const tempPassword = generateTempPassword();
  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password: tempPassword,
    email_confirm: true,
    app_metadata: {
      role: companyRole === "company_admin" ? "manager" : "employee", // kept for the current admin panel
      company_id: companyId,
      company_role: companyRole,
      must_change_password: mustChangePassword,
    },
    user_metadata: { full_name: fullName, department: department || null },
  });

  if (createError || !created?.user) {
    const code = (createError as { code?: string } | null)?.code;
    if (code === "email_exists" || createError?.status === 422) return json({ error: "email_exists" }, 409);
    console.error("createUser failed", createError?.message);
    return json({ error: "create_failed" }, 500);
  }

  // 6) Full HR profile in one DB transaction, as the calling admin (the DB checks the company again)
  if (saveProfile) {
    const { error: profileError } = await userClient.rpc("admin_save_employee_profile", {
      p_employee_id: created.user.id,
      p_employee_number: employeeNumber,
      p_full_name: fullName,
      p_department: department,
      p_job_title: body.job_title ?? null,
      p_gender: body.gender ?? null,
      p_birth_date: body.birth_date ?? null,
      p_hire_date: body.hire_date ?? null,
      p_work_location_id: body.work_location_id ?? null,
      p_is_active: true,
      p_geofence_required: geofenceRequired,
      p_base_salary: body.base_salary ?? null,
      p_components: body.components ?? [],
      p_schedule: body.schedule ?? null,
      p_leave: body.leave ?? {},
    });

    if (profileError) {
      await admin.auth.admin.deleteUser(created.user.id); // no half-created employee
      const code = profileError.message;
      if (PROFILE_ERRORS.has(code)) return json({ error: code }, code === "employee_number_exists" ? 409 : 400);
      console.error("profile save failed", profileError.message);
      return json({ error: "create_failed" }, 500);
    }
  }

  await admin.rpc("service_audit_write", {
    p_company_id: companyId,
    p_actor_id: userData.user.id,
    p_action: companyRole === "company_admin" ? "account.create_admin" : "account.create_employee",
    p_target_type: "employee",
    p_target_id: created.user.id,
    p_details: { email, must_change_password: mustChangePassword },
  });

  return json({
    user_id: created.user.id,
    email,
    temporary_password: tempPassword,
    must_change_password: mustChangePassword,
    geofence_required: geofenceRequired,
    company_id: companyId,
    company_role: companyRole,
  }, 201);
});
