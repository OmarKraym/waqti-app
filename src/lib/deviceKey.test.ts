import { describe, expect, it } from "vitest";
import { getDeviceKey, mustInstallFirst } from "./deviceKey";

const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) }; };

describe("device key: one secret per phone, kept forever", () => {
  it("is created once and then always the same", () => {
    const st = mem();
    const k = getDeviceKey(st);
    expect(k).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(getDeviceKey(st)).toBe(k);
  });
  it("two phones get different keys", () => expect(getDeviceKey(mem())).not.toBe(getDeviceKey(mem())));
  it("a damaged saved value is replaced", () => {
    const st = mem();
    st.setItem("waqti-device-key", "bad");
    expect(getDeviceKey(st)).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });
  it("blocked storage: null (the app then says the phone cannot be bound)", () => {
    const bad = { getItem: () => { throw new Error("x"); }, setItem: () => { throw new Error("x"); } };
    expect(getDeviceKey(bad)).toBeNull();
  });
});

describe("iPhone: bind only inside the installed app (Safari and the app keep separate storage)", () => {
  const iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 Version/17.2 Mobile/15E148 Safari/604.1";
  const android = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36";
  it("iPhone in Safari -> install first", () => expect(mustInstallFirst(iphone, false)).toBe(true));
  it("iPhone installed -> fine", () => expect(mustInstallFirst(iphone, true)).toBe(false));
  it("Android tab -> fine (Chrome and the installed app share storage)", () => expect(mustInstallFirst(android, false)).toBe(false));
});
