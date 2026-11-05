import { describe, expect, it } from "vitest";
import { loadSnapshot, saveSnapshot } from "./snapshot";

function memStore() {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), m };
}

describe("snapshot (a copy of server data on this phone)", () => {
  it("returns what was saved, with the time it was saved", () => {
    const s = memStore();
    saveSnapshot("requests", "u1", { a: 1 }, 1000, s);
    expect(loadSnapshot<{ a: number }>("requests", "u1", s)).toEqual({ data: { a: 1 }, saved_at_ms: 1000 });
  });

  it("keeps each account and each kind apart", () => {
    const s = memStore();
    saveSnapshot("requests", "u1", { a: 1 }, 1, s);
    expect(loadSnapshot("requests", "u2", s)).toBeNull();
    expect(loadSnapshot("overtime", "u1", s)).toBeNull();
  });

  it("ignores broken data and never throws", () => {
    const s = memStore();
    s.m.set("waqti-snap:requests:u1", "{not json");
    expect(loadSnapshot("requests", "u1", s)).toBeNull();
    s.m.set("waqti-snap:requests:u1", JSON.stringify({ data: 1 }));
    expect(loadSnapshot("requests", "u1", s)).toBeNull();
    const full = { getItem: () => null, setItem: () => { throw new Error("full"); } };
    expect(() => saveSnapshot("requests", "u1", { a: 1 }, 1, full)).not.toThrow();
    expect(loadSnapshot("requests", "u1", null)).toBeNull();
  });
});
