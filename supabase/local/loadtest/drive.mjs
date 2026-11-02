// 60 employees against the emulated API (local only). Prints one block per wave and checks the database at the end.
import crypto from "node:crypto";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const BASE = `http://127.0.0.1:${process.env.PORT ?? 3999}`;
const SECRET = process.env.JWT_SECRET;
const DB = process.env.DB;
const ids = fs.readFileSync(`${process.env.LOADDIR ?? "/tmp/loadapi"}/ids.txt`, "utf8").trim().split("\n");
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (sub) => {
  const h = b64({ alg: "HS256", typ: "JWT" });
  const p = b64({ sub, role: "authenticated", aud: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600, app_metadata: {} });
  return `${h}.${p}.${crypto.createHmac("sha256", SECRET).update(`${h}.${p}`).digest("base64url")}`;
};
const tokens = ids.map(jwt);
const psql = (q) => execFileSync("psql", ["-X", "-qAt", "-d", DB, "-c", q], { encoding: "utf8" }).trim();
const uuid = () => crypto.randomUUID();

async function call(i, fn, args = {}, token = tokens[i]) {
  const t0 = performance.now();
  let status = 0, body = null;
  try {
    const r = await fetch(`${BASE}/rpc/${fn}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(args) });
    status = r.status; body = await r.json().catch(() => null);
  } catch (e) { status = -1; body = { message: String(e) }; }
  return { status, body, ms: performance.now() - t0 };
}
const punchArgs = (action, rid = uuid()) => ({ p_request_id: rid, p_expected_action: action, p_reading: "not_requested", p_lat: null, p_lng: null, p_accuracy_m: null, p_biometric: "ticket" });

const pct = (a, q) => a[Math.min(a.length - 1, Math.floor(a.length * q))];
function report(name, results) {
  const ms = results.map((r) => r.ms).sort((a, b) => a - b);
  const codes = {};
  for (const r of results) { const k = r.status === 200 ? "200" : `${r.status} ${r.body?.message ?? ""}`.slice(0, 70); codes[k] = (codes[k] ?? 0) + 1; }
  console.log(`--- ${name}: ${results.length} calls | ms min=${ms[0].toFixed(0)} p50=${pct(ms, 0.5).toFixed(0)} p95=${pct(ms, 0.95).toFixed(0)} max=${ms.at(-1).toFixed(0)} | ${Object.entries(codes).map(([k, v]) => `${v}x[${k}]`).join(" ")}`);
}
async function wave(name, makers) { // makers: array of () => Promise; all start in the same tick
  const out = await Promise.all(makers.map((m) => m()));
  report(name, out.flat());
  return out;
}

// Warm-up: one call each, so the first wave does not pay for connection setup of the very first request.
await call(0, "employee_attendance_state");
console.log(`pool=${process.env.POOL} acq=${process.env.ACQ_MS ?? 10000}ms, ${ids.length} employees`);

await wave("W1 app opens (state)", ids.map((_, i) => () => call(i, "employee_attendance_state")));
const w2 = await wave("W2 check-in rush", ids.map((_, i) => () => call(i, "employee_punch", punchArgs("check_in"))));
const actions2 = {}; for (const r of w2) actions2[r.body?.action ?? "-"] = (actions2[r.body?.action ?? "-"] ?? 0) + 1;
console.log("    result actions:", JSON.stringify(actions2));
console.log("    db after W2:", psql("select count(*) filter (where event_type='check_in') || ' check_in events, ' || (select count(*) from attendance_sessions where status='open') || ' open sessions' from attendance_events"));

// Double tap: the same request id sent twice at the same moment.
const rids = ids.map(() => uuid());
const w3 = await wave("W3 check-out double-tap (same request id x2)", ids.flatMap((_, i) => [() => call(i, "employee_punch", punchArgs("check_out", rids[i])), () => call(i, "employee_punch", punchArgs("check_out", rids[i]))]));
console.log("    db after W3:", psql("select count(*) filter (where event_type='check_out') || ' check_out events, ' || (select count(*) from attendance_sessions where status='open') || ' open sessions' from attendance_events"));

// Same person, two DIFFERENT request ids at the same moment (two phones / a retry with a new id): exactly one may win.
const w4 = await wave("W4 check-in x2 per person (different request ids)", ids.flatMap((_, i) => [() => call(i, "employee_punch", punchArgs("check_in")), () => call(i, "employee_punch", punchArgs("check_in"))]));
const w4ok = w4.filter((r) => r.status === 200).length, w4bad = w4.filter((r) => r.status !== 200);
console.log(`    winners=${w4ok} (expected ${ids.length}) refused=${w4bad.length}:`, [...new Set(w4bad.map((r) => `${r.status} ${r.body?.message}`))].join(" | ").slice(0, 160));
console.log("    db after W4:", psql("select count(*) filter (where event_type='check_in') || ' check_in events, ' || (select count(*) from attendance_sessions where status='open') || ' open sessions, max open per person=' || coalesce((select max(n) from (select count(*) n from attendance_sessions where status='open' group by employee_id) q),0) from attendance_events"));

// A realistic burst: every employee opens the app, punches out and opens the requests screen, all at once.
await wave("W5 chains (state -> punch out -> overview + leave window)", ids.map((_, i) => async () => {
  const a = await call(i, "employee_attendance_state");
  const b = await call(i, "employee_punch", punchArgs("check_out"));
  const [c, d] = await Promise.all([call(i, "employee_requests_overview"), call(i, "employee_leave_window")]);
  return [a, b, c, d];
}));
// Authentication still holds under load: a forged token and a missing function are refused.
const forged = await call(0, "employee_attendance_state", {}, tokens[0].slice(0, -3) + "AAA");
const missing = await call(0, "no_such_function");
console.log(`--- control: forged token -> ${forged.status}, unknown function -> ${missing.status}`);
console.log("    final db:", psql("select (select count(*) from attendance_events) || ' events, ' || (select count(*) from attendance_sessions where status='open') || ' open, ' || (select count(*) from (select employee_id from attendance_sessions where status='open' group by 1 having count(*)>1) q) || ' people with 2+ open sessions'"));
