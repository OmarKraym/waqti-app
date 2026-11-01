import { describe, expect, it } from "vitest";
import { clearDeviceHint, readDeviceHint, saveDeviceHint } from "./bioDevice";

function fakeStorage(initial: Record<string, string> = {}) {
  const m = new Map(Object.entries(initial));
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
    raw: m,
  };
}

describe("the phone remembers which fingerprint belongs to it (no secret, only the credential id)", () => {
  it("nothing saved: null", () => {
    expect(readDeviceHint(fakeStorage())).toBeNull();
  });
  it("saves and reads the credential id", () => {
    const s = fakeStorage();
    saveDeviceHint("abc_DEF-123", s);
    expect(readDeviceHint(s)).toBe("abc_DEF-123");
  });
  it("clear forgets it", () => {
    const s = fakeStorage();
    saveDeviceHint("abc", s);
    clearDeviceHint(s);
    expect(readDeviceHint(s)).toBeNull();
  });
  it("ignores values that are not a credential id (empty, huge, odd characters, JSON)", () => {
    const s = fakeStorage();
    saveDeviceHint("", s);
    expect(readDeviceHint(s)).toBeNull();
    saveDeviceHint("x".repeat(2000), s);
    expect(readDeviceHint(s)).toBeNull();
    saveDeviceHint('a"b<script>', s);
    expect(readDeviceHint(s)).toBeNull();
    s.raw.set("waqti-bio-device", '{"credential_id":"x"}');
    expect(readDeviceHint(s)).toBeNull();
  });
  it("blocked storage never throws", () => {
    const bad = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); }, removeItem: () => { throw new Error("blocked"); } };
    expect(readDeviceHint(bad)).toBeNull();
    expect(() => saveDeviceHint("abc", bad)).not.toThrow();
    expect(() => clearDeviceHint(bad)).not.toThrow();
  });
});
