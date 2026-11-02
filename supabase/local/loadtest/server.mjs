// Emulates what PostgREST does for one RPC call, in front of a LOCAL Postgres (test only):
//   verify JWT -> take a connection from a limited pool (wait at most ACQ_MS, else 503) -> begin ->
//   set local role authenticated -> set request.jwt.claims -> call the function -> commit.
// It is NOT PostgREST. It shows what happens when many calls compete for few database connections.
import http from "node:http";
import crypto from "node:crypto";
import pg from "pg";

const POOL = Number(process.env.POOL ?? 10);
const ACQ_MS = Number(process.env.ACQ_MS ?? 10000);
const SECRET = process.env.JWT_SECRET;
const PORT = Number(process.env.PORT ?? 3999);
const pool = new pg.Pool({ host: "/var/run/postgresql", user: "postgres", database: process.env.DB, max: POOL, connectionTimeoutMillis: ACQ_MS });

const SQL = {
  employee_attendance_state: "select public.employee_attendance_state() as r",
  employee_requests_overview: "select public.employee_requests_overview() as r",
  employee_leave_window: "select public.employee_leave_window() as r",
  employee_punch: `select public.employee_punch(p_request_id := a.p_request_id, p_expected_action := a.p_expected_action, p_reading := a.p_reading,
      p_lat := a.p_lat, p_lng := a.p_lng, p_accuracy_m := a.p_accuracy_m, p_biometric := a.p_biometric) as r
    from json_to_record($1::json) as a(p_request_id uuid, p_expected_action text, p_reading text, p_lat float8, p_lng float8, p_accuracy_m float8, p_biometric text)`,
};

function verify(token) {
  const [h, p, s] = (token ?? "").split(".");
  if (!h || !p || !s) return null;
  const good = crypto.createHmac("sha256", SECRET).update(`${h}.${p}`).digest("base64url");
  if (good.length !== s.length || !crypto.timingSafeEqual(Buffer.from(good), Buffer.from(s))) return null;
  const claims = JSON.parse(Buffer.from(p, "base64url").toString());
  return claims.exp && claims.exp < Date.now() / 1000 ? null : claims;
}
const send = (res, code, body) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };

http.createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;
  const fn = (req.url ?? "").replace(/^\/rpc\//, "");
  const claims = verify((req.headers.authorization ?? "").replace(/^Bearer /, ""));
  if (!claims) return send(res, 401, { message: "JWT invalid" });
  if (!SQL[fn]) return send(res, 404, { message: "no such function" });
  let c;
  try { c = await pool.connect(); } catch { return send(res, 503, { message: "pool acquisition timeout" }); }
  try {
    await c.query("begin");
    await c.query("set local role authenticated");
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    const r = await c.query(SQL[fn], SQL[fn].includes("$1") ? [body || "{}"] : []);
    await c.query("commit");
    c.release();
    send(res, 200, r.rows[0]?.r ?? null);
  } catch (e) {
    try { await c.query("rollback"); } catch {}
    c.release();
    send(res, e.code === "42501" ? 403 : e.code === "P0001" ? 400 : 500, { code: e.code, message: e.message });
  }
}).listen(PORT, "127.0.0.1", () => console.log(`listening ${PORT} pool=${POOL} acq=${ACQ_MS}ms`));
