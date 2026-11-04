import { afterEach, describe, expect, it, vi } from "vitest";
import { newRequestId } from "./attendance";
import { fetchWithTimeout, fromPostgrest } from "./supabaseApi";

// Error shapes as returned by PostgREST for the real Waqti functions (verified on production 2026-10-29).
describe("server error mapping", () => {
  it("account errors raised with 42501 keep their own reason", () => {
    expect(fromPostgrest({ code: "42501", message: "employee_inactive" }).code).toBe("employee_inactive");
    expect(fromPostgrest({ code: "42501", message: "must_change_password" }).code).toBe("must_change_password");
    expect(fromPostgrest({ code: "42501", message: "not_authenticated" }).code).toBe("not_authenticated");
  });

  it("a real permission error stays forbidden", () => {
    expect(fromPostgrest({ code: "42501", message: "permission denied for function employee_punch" }).code).toBe("forbidden");
  });

  it("attendance decisions map by message whatever the SQLSTATE", () => {
    expect(fromPostgrest({ code: "22023", message: "outside_geofence" }).code).toBe("outside_geofence");
    expect(fromPostgrest({ code: "22023", message: "location_required" }).code).toBe("location_required");
    expect(fromPostgrest({ code: "22023", message: "geofence_not_configured" }).code).toBe("geofence_not_configured");
    expect(fromPostgrest({ code: "P0001", message: "state_changed" }).code).toBe("state_changed");
    expect(fromPostgrest({ code: "P0001", message: "rate_limited" }).code).toBe("rate_limited");
  });

  it("expired token = not_authenticated", () => {
    expect(fromPostgrest({ code: "PGRST303", message: "JWT expired" }).code).toBe("not_authenticated");
  });

  it("no SQLSTATE = no server answer = network (unknown outcome)", () => {
    expect(fromPostgrest({ code: "", message: "TypeError: Failed to fetch" }).code).toBe("network");
  });

  it("anything else = unknown", () => {
    expect(fromPostgrest({ code: "XX000", message: "boom" }).code).toBe("unknown");
  });
});

describe("fetchWithTimeout (no AbortSignal.any needed)", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("aborts a request that takes too long", async () => {
    vi.stubGlobal("fetch", (_: unknown, init: RequestInit) =>
      new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(new Error("aborted")))));
    await expect(fetchWithTimeout("https://x.test", {}, 20)).rejects.toThrow("aborted");
  });

  it("also aborts when the caller's own signal aborts", async () => {
    vi.stubGlobal("fetch", (_: unknown, init: RequestInit) =>
      new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(new Error("aborted")))));
    const outer = new AbortController();
    const p = fetchWithTimeout("https://x.test", { signal: outer.signal }, 10_000);
    outer.abort();
    await expect(p).rejects.toThrow("aborted");
  });

  it("returns the response when the server answers in time", async () => {
    vi.stubGlobal("fetch", async () => new Response("ok"));
    await expect((await fetchWithTimeout("https://x.test", {}, 1000)).text()).resolves.toBe("ok");
  });
});

describe("request id", () => {
  it("falls back to getRandomValues when randomUUID is missing (older phones)", () => {
    const id = newRequestId({ getRandomValues: (a) => crypto.getRandomValues(a) });
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it("is different every time", () => {
    const fake = { getRandomValues: (a: Uint8Array<ArrayBuffer>) => crypto.getRandomValues(a) } as Pick<Crypto, "getRandomValues">;
    expect(newRequestId(fake)).not.toBe(newRequestId(fake));
  });
});

import { authStorageKey, storedSessionUser } from "./supabaseApi";

describe("staying signed in when the app opens offline", () => {
  const key = authStorageKey("https://fgnbdlqmtezneznwvahf.supabase.co");
  const store = (entries: Record<string, string>) => ({ getItem: (k: string) => entries[k] ?? null });
  const user = { id: "u1", email: "e@x.ly", app_metadata: { must_change_password: false } };

  it("uses the same storage key as supabase-js", () => {
    expect(key).toBe("sb-fgnbdlqmtezneznwvahf-auth-token");
  });

  it("reads the saved user even when the access token has expired", () => {
    const raw = JSON.stringify({ access_token: "old", refresh_token: "r", expires_at: 1, user });
    expect(storedSessionUser(store({ [key]: raw }), key)).toEqual({ id: "u1", email: "e@x.ly", mustChangePassword: false });
  });

  it("also works when supabase-js keeps the user in a separate key", () => {
    const raw = JSON.stringify({ access_token: "old", refresh_token: "r", expires_at: 1 });
    expect(storedSessionUser(store({ [key]: raw, [`${key}-user`]: JSON.stringify({ user }) }), key)?.id).toBe("u1");
  });

  it("no saved session, no refresh token, or broken data = signed out", () => {
    expect(storedSessionUser(store({}), key)).toBeNull();
    expect(storedSessionUser(store({ [key]: JSON.stringify({ user }) }), key)).toBeNull();
    expect(storedSessionUser(store({ [key]: "{broken" }), key)).toBeNull();
    expect(storedSessionUser(null, key)).toBeNull();
  });
});

describe("one phone per account: bind, rebind once, lock out", () => {
  afterEach(() => vi.unstubAllGlobals());
  const store = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) }; };

  function fakeServer(answers: Record<string, Array<{ status: number; body: unknown }>>) {
    const calls: string[] = [];
    vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
      const url = String(input instanceof Request ? input.url : input);
      const fn = url.split("/rpc/")[1]?.split("?")[0] ?? url;
      calls.push(fn);
      const next = answers[fn]?.shift() ?? { status: 200, body: {} };
      return new Response(JSON.stringify(next.body), { status: next.status, headers: { "content-type": "application/json" } });
    });
    vi.stubGlobal("navigator", { onLine: true, userAgent: "test-phone" });
    vi.stubGlobal("localStorage", store());
    vi.stubGlobal("sessionStorage", store());
    return calls;
  }

  it("maps the new server codes", () => {
    expect(fromPostgrest({ code: "42501", message: "device_locked" }).code).toBe("device_locked");
    expect(fromPostgrest({ code: "42501", message: "device_not_bound" }).code).toBe("device_not_bound");
    expect(fromPostgrest({ code: "42501", message: "login_again" }).code).toBe("login_again");
  });

  it("a call that meets device_not_bound binds this phone and is retried once", async () => {
    const calls = fakeServer({
      employee_overtime_overview: [{ status: 403, body: { code: "42501", message: "device_not_bound" } }, { status: 200, body: { items: [] } }],
      employee_bind_device: [{ status: 200, body: { ok: true } }],
    });
    const { createSupabaseApi } = await import("./supabaseApi");
    const api = createSupabaseApi("https://x.supabase.co", "pk");
    await expect(api.getOvertimeOverview()).resolves.toEqual({ items: [] });
    expect(calls).toEqual(["employee_overtime_overview", "employee_bind_device", "employee_overtime_overview"]);
  });

  it("another phone: the session ends and the sign-in screen is told why", async () => {
    const calls = fakeServer({
      employee_overtime_overview: [{ status: 403, body: { code: "42501", message: "device_not_bound" } }],
      employee_bind_device: [{ status: 403, body: { code: "42501", message: "device_locked" } }],
    });
    const { createSupabaseApi } = await import("./supabaseApi");
    const api = createSupabaseApi("https://x.supabase.co", "pk");
    await expect(api.getOvertimeOverview()).rejects.toMatchObject({ code: "device_locked" });
    expect(sessionStorage.getItem("waqti-signout-reason")).toBe("device_locked");
    expect(calls.filter((c) => c === "employee_overtime_overview")).toHaveLength(1); // no endless retry
  });

  it("bindDevice sends this phone's key (never changes between calls)", async () => {
    const bodies: string[] = [];
    fakeServer({});
    vi.stubGlobal("fetch", async (_: unknown, init?: RequestInit) => { bodies.push(String(init?.body)); return new Response("{}", { status: 200 }); });
    const { createSupabaseApi } = await import("./supabaseApi");
    const api = createSupabaseApi("https://x.supabase.co", "pk");
    await api.bindDevice();
    await api.bindDevice();
    const k = (b: string) => JSON.parse(b).p_key;
    expect(k(bodies[0])).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(k(bodies[1])).toBe(k(bodies[0]));
  });
});

describe("app updated before the database", () => {
  afterEach(() => vi.unstubAllGlobals());
  it("bindDevice is a no-op when the server has no phone lock yet", async () => {
    vi.stubGlobal("navigator", { onLine: true, userAgent: "test-phone" });
    const m = new Map<string, string>();
    vi.stubGlobal("localStorage", { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) });
    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ code: "PGRST202", message: "Could not find the function public.employee_bind_device(p_key, p_user_agent) in the schema cache" }), { status: 404 }));
    const { createSupabaseApi } = await import("./supabaseApi");
    await expect(createSupabaseApi("https://x.supabase.co", "pk").bindDevice()).resolves.toBeUndefined();
  });
});
