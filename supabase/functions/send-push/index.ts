// send-push: sends the queued notifications (public.notifications) as Web Push.
// Called by the database (pg_net) right after notifications are queued, and every minute by pg_cron.
// Protected by a shared secret header (x-waqti-cron); deployed with verify_jwt = false.
// Secrets: WAQTI_CRON_SECRET, VAPID_PRIVATE_JWK (EC P-256 JWK with d), VAPID_SUBJECT (https: or mailto:).
// The response holds counts only, never notification content.
import { createClient } from "npm:@supabase/supabase-js@2";
import { sendPush, vapidFromJwk, type Vapid } from "./webpush.ts";

interface Claimed {
  id: number;
  title: string;
  body: string;
  url: string;
  tag: string | null;
  kind: string;
  ttl: number;
  subscriptions: { endpoint: string; p256dh: string; auth: string }[];
}

let vapid: Promise<Vapid> | null = null;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

function sameSecret(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  const secret = Deno.env.get("WAQTI_CRON_SECRET") ?? "";
  if (req.method !== "POST" || secret.length < 32 || !sameSecret(req.headers.get("x-waqti-cron") ?? "", secret)) {
    return json({ error: "forbidden" }, 403);
  }
  vapid ??= vapidFromJwk(JSON.parse(Deno.env.get("VAPID_PRIVATE_JWK") ?? "{}"), Deno.env.get("VAPID_SUBJECT") ?? "https://omarkraym.github.io/waqti-app/");
  let v: Vapid;
  try {
    v = await vapid;
  } catch (e) {
    vapid = null;
    console.error("bad VAPID key", String(e));
    return json({ error: "config" }, 500);
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let processed = 0, delivered = 0, failed = 0, gone = 0;
  for (let round = 0; round < 10; round++) {
    const { data, error } = await admin.rpc("push_claim_batch", { p_limit: 50 });
    if (error) {
      console.error("claim failed", error.message);
      return json({ error: "claim_failed", processed }, 500);
    }
    const batch = (data ?? []) as Claimed[];
    if (batch.length === 0) break;

    const results = await Promise.all(batch.map(async (n) => {
      const goneHere: string[] = [];
      const deliveredHere: string[] = [];
      let lastError: string | null = null;
      for (const s of n.subscriptions) {
        try {
          const r = await sendPush(s, { title: n.title, body: n.body, url: n.url, tag: n.tag, kind: n.kind }, v,
                                   { ttl: n.ttl, urgency: n.kind.startsWith("reminder") || n.kind === "approval_needed" ? "high" : "normal" });
          if (r.status === 404 || r.status === 410) goneHere.push(s.endpoint);
          else if (r.status >= 200 && r.status < 300) deliveredHere.push(s.endpoint);
          else lastError = `${r.status} ${r.body}`;
        } catch (e) {
          lastError = String(e).slice(0, 200);
        }
      }
      // Done when at least one device accepted it, or when no device is left to try.
      const ok = deliveredHere.length > 0 || goneHere.length === n.subscriptions.length;
      delivered += deliveredHere.length;
      gone += goneHere.length;
      if (!ok) failed += 1;
      return { id: n.id, ok, error: n.subscriptions.length === 0 ? "no_device" : lastError, gone: goneHere, delivered: deliveredHere };
    }));

    const { error: reportError } = await admin.rpc("push_report", { p_results: results });
    if (reportError) console.error("report failed", reportError.message);
    processed += batch.length;
    if (batch.length < 50) break;
  }
  return json({ processed, delivered, failed, gone });
});
