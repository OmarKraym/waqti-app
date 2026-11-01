import { describe, expect, it } from "vitest";
import { AppError } from "./errors";
import {
  anchorFromCache,
  anchorFromServer,
  anchorOffsetMs,
  failedOf,
  loadCachedState,
  loadQueue,
  makeQueuedPunch,
  pendingOf,
  saveCachedState,
  saveQueue,
  syncQueue,
  toOfflineInput,
  withQueue,
  type QueuedPunch,
  type Storage,
  type TimeAnchor,
} from "./offlineQueue";
import type { AttendanceState, OfflinePunchInput, PunchResult } from "./types";

function memoryStorage(): Storage & { data: Map<string, string> } {
  const data = new Map<string, string>();
  return {
    data,
    getItem: (k) => data.get(k) ?? null,
    setItem: (k, v) => void data.set(k, v),
    removeItem: (k) => void data.delete(k),
  };
}

const T0 = Date.UTC(2026, 9, 30, 7, 0, 0); // 09:00 Tripoli

const base: AttendanceState = {
  employee: { full_name: "موظف", employee_number: "1" },
  company: { name: "شركة", timezone: "Africa/Tripoli" },
  next_action: "check_in",
  open_session: null,
  location_policy: "record",
  outside_action: "flag",
  max_accuracy_m: 100,
  recent_events: [],
  server_time: new Date(T0).toISOString(),
  time_token: "tok-T0",
  punch_window: { allowed: true, opens_at: null, closes_at: null, reason: "no_limits" },
  biometric: { policy: "off", has_device: false },
};

/** Server says T0; the phone clock is 10 minutes slow; perf clock was at 1000 ms. */
const anchor: TimeAnchor = { token: "tok-T0", server_time_ms: T0, device_time_ms: T0 - 600_000, perf_ms: 1000 };

function punch(id: string, action: "check_in" | "check_out", minutes: number): QueuedPunch {
  return makeQueuedPunch(id, action, { kind: "denied" }, anchor, anchor.device_time_ms + minutes * 60_000, 1000 + minutes * 60_000);
}

function ok(input: OfflinePunchInput): PunchResult {
  return {
    event_id: `e-${input.request_id}`, action: input.expected_action, server_time: input.device_time,
    location_status: "unavailable", needs_review: false, duplicate: false,
  };
}

describe("time anchor", () => {
  it("measures server minus phone clock", () => {
    expect(anchorOffsetMs(anchor)).toBe(600_000);
  });

  it("from a server answer: keeps the token, the phone clock and the monotonic clock", () => {
    const a = anchorFromServer("t", new Date(T0).toISOString(), T0 - 5000, 42);
    expect(a).toEqual({ token: "t", server_time_ms: T0, device_time_ms: T0 - 5000, perf_ms: 42 });
  });

  it("from the cache (app restarted): no monotonic clock", () => {
    const a = anchorFromCache({ data: base, saved_at_ms: T0 - 3000 });
    expect(a.perf_ms).toBeNull();
    expect(a.token).toBe("tok-T0");
  });
});

describe("making an offline punch", () => {
  it("shows the tap time corrected to the server clock", () => {
    const q = punch("r1", "check_in", 30);
    expect(q.offline_at).toBe(new Date(T0 + 30 * 60_000).toISOString());
    expect(q.status).toBe("pending");
  });

  it("records the monotonic time since the anchor when the app stayed open", () => {
    expect(punch("r1", "check_in", 30).monotonic_ms).toBe(30 * 60_000);
  });

  it("no monotonic time when the anchor came from storage", () => {
    const q = makeQueuedPunch("r1", "check_in", { kind: "denied" }, { ...anchor, perf_ms: null }, T0, 5000);
    expect(q.monotonic_ms).toBeNull();
  });

  it("sends exactly what the server needs to check the clock", () => {
    const q = punch("r1", "check_in", 30);
    const input = toOfflineInput(q, T0 + 3_600_000);
    expect(input).toEqual({
      request_id: "r1",
      expected_action: "check_in",
      reading: { kind: "denied" },
      time_token: "tok-T0",
      token_device_time: new Date(T0 - 600_000).toISOString(),
      device_time: new Date(T0 - 600_000 + 30 * 60_000).toISOString(),
      monotonic_ms: 30 * 60_000,
      device_now: new Date(T0 + 3_600_000).toISOString(),
    });
  });
});

describe("screen with punches waiting on the phone", () => {
  it("nothing waiting = the server state as is", () => {
    expect(withQueue(base, [])).toBe(base);
  });

  it("a waiting check-in flips the button to check-out and opens a session at its time", () => {
    const v = withQueue(base, [punch("a", "check_in", 0)]);
    expect(v.next_action).toBe("check_out");
    expect(v.open_session?.started_at).toBe(new Date(T0).toISOString());
    expect(v.recent_events[0]).toMatchObject({ id: "queued:a", action: "check_in" });
  });

  it("check-in + check-out waiting = back to check-in, no open session", () => {
    const v = withQueue(base, [punch("a", "check_in", 0), punch("b", "check_out", 480)]);
    expect(v.next_action).toBe("check_in");
    expect(v.open_session).toBeNull();
    expect(v.recent_events.map((e) => e.id)).toEqual(["queued:b", "queued:a"]);
  });

  it("refused punches do not change the button", () => {
    const failed = { ...punch("a", "check_in", 0), status: "failed" as const };
    expect(withQueue(base, [failed]).next_action).toBe("check_in");
  });
});

describe("sending the queue", () => {
  it("sends in order with the CURRENT phone time, and empties the queue", async () => {
    const seen: [string, string][] = [];
    const r = await syncQueue([punch("a", "check_in", 0), punch("b", "check_out", 480)], async (i) => {
      seen.push([i.request_id, i.device_now]);
      return ok(i);
    }, () => T0 + 10 * 3_600_000);
    expect(seen.map((s) => s[0])).toEqual(["a", "b"]);
    expect(seen[0][1]).toBe(new Date(T0 + 10 * 3_600_000).toISOString());
    expect(r.queue).toEqual([]);
    expect(r.sent).toHaveLength(2);
  });

  it("no connection: stops and keeps everything not yet sent", async () => {
    let calls = 0;
    const r = await syncQueue([punch("a", "check_in", 0), punch("b", "check_out", 480)], async (i) => {
      calls += 1;
      if (i.request_id === "b") throw new AppError("network");
      return ok(i);
    });
    expect(calls).toBe(2);
    expect(r.queue.map((q) => q.request_id)).toEqual(["b"]);
    expect(r.stoppedOffline).toBe(true);
  });

  it("a refused punch is kept as failed with its reason; later ones are still tried", async () => {
    const r = await syncQueue([punch("a", "check_in", 0), punch("b", "check_out", 480)], async (i) => {
      if (i.request_id === "a") throw new AppError("clock_changed");
      throw new AppError("state_changed");
    });
    expect(failedOf(r.queue).map((q) => [q.request_id, q.error_code])).toEqual([
      ["a", "clock_changed"],
      ["b", "state_changed"],
    ]);
    expect(r.refused).toHaveLength(2);
    expect(pendingOf(r.queue)).toHaveLength(0);
  });

  it("failed punches are never sent again", async () => {
    const failed = { ...punch("a", "check_in", 0), status: "failed" as const, error_code: "outside_geofence" as const };
    const sent: string[] = [];
    await syncQueue([failed, punch("b", "check_in", 60)], async (i) => {
      sent.push(i.request_id);
      return ok(i);
    });
    expect(sent).toEqual(["b"]);
  });

  it("expired login stops the sync and keeps the queue for later", async () => {
    await expect(
      syncQueue([punch("a", "check_in", 0)], async () => {
        throw new AppError("not_authenticated");
      }),
    ).rejects.toMatchObject({ code: "not_authenticated" });
  });

  it("the same request_id is sent again on retry (server answers duplicate, nothing doubled)", async () => {
    const seen: string[] = [];
    const q = [punch("same-id", "check_in", 0)];
    await syncQueue(q, async () => { throw new AppError("network"); });
    await syncQueue(q, async (i) => { seen.push(i.request_id); return { ...ok(i), duplicate: true }; });
    expect(seen).toEqual(["same-id"]);
  });
});

describe("storage on the phone", () => {
  it("queue is saved per user and survives a reload", () => {
    const s = memoryStorage();
    expect(saveQueue(s, "u1", [punch("a", "check_in", 0)])).toBe(true);
    expect(loadQueue(s, "u1").map((q) => q.request_id)).toEqual(["a"]);
    expect(loadQueue(s, "u2")).toEqual([]);
  });

  it("an empty queue removes the key", () => {
    const s = memoryStorage();
    saveQueue(s, "u1", [punch("a", "check_in", 0)]);
    saveQueue(s, "u1", []);
    expect(s.data.size).toBe(0);
  });

  it("blocked storage: saving reports failure (the punch must not be shown as saved)", () => {
    const broken: Storage = {
      getItem: () => null,
      setItem: () => { throw new Error("QuotaExceededError"); },
      removeItem: () => undefined,
    };
    expect(saveQueue(broken, "u1", [punch("a", "check_in", 0)])).toBe(false);
    expect(saveQueue(null, "u1", [punch("a", "check_in", 0)])).toBe(false);
  });

  it("corrupted data, or items from an older format without a time token, are dropped", () => {
    const s = memoryStorage();
    s.setItem("waqti-queue:u1", "{not json");
    expect(loadQueue(s, "u1")).toEqual([]);
    s.setItem("waqti-queue:u1", JSON.stringify([{ request_id: "old", offline_at: "x", device_time_ms: 1 }]));
    expect(loadQueue(s, "u1")).toEqual([]);
  });

  it("last server state is cached per user; a cache without a token is ignored", () => {
    const s = memoryStorage();
    saveCachedState(s, "u1", { data: base, saved_at_ms: T0 });
    expect(loadCachedState(s, "u1")?.saved_at_ms).toBe(T0);
    expect(loadCachedState(s, "u2")).toBeNull();
    s.setItem("waqti-state:u3", JSON.stringify({ data: { ...base, time_token: undefined }, saved_at_ms: T0 }));
    expect(loadCachedState(s, "u3")).toBeNull();
  });
});
