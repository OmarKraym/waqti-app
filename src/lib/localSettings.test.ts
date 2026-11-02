import { describe, expect, it } from "vitest";
import { readNotificationPrefs, saveNotificationPrefs } from "./localSettings";

function memory(initial: Record<string, string> = {}) {
  const m = new Map(Object.entries(initial));
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), dump: () => Object.fromEntries(m) };
}
const prefs = { remind_check_in: true, check_in_before: 15, remind_check_out: false, check_out_before: 0 };

describe("reminder choices kept on the phone", () => {
  it("what is saved comes back, per user", () => {
    const s = memory();
    saveNotificationPrefs("u1", prefs, s);
    expect(readNotificationPrefs("u1", s)).toEqual(prefs);
    expect(readNotificationPrefs("u2", s)).toBeNull();
  });
  it("only the choices are stored (not the number of devices)", () => {
    const s = memory();
    saveNotificationPrefs("u1", { ...prefs, devices: 3 } as never, s);
    expect(JSON.parse(s.dump()["waqti-notif:u1"])).toEqual(prefs);
  });
  it("nothing saved, broken or tampered data is ignored", () => {
    expect(readNotificationPrefs("u1", memory())).toBeNull();
    expect(readNotificationPrefs("u1", memory({ "waqti-notif:u1": "not json" }))).toBeNull();
    expect(readNotificationPrefs("u1", memory({ "waqti-notif:u1": JSON.stringify({ ...prefs, check_in_before: -5 }) }))).toBeNull();
    expect(readNotificationPrefs("u1", memory({ "waqti-notif:u1": JSON.stringify({ ...prefs, remind_check_in: "yes" }) }))).toBeNull();
    expect(readNotificationPrefs("u1", memory({ "waqti-notif:u1": JSON.stringify({ ...prefs, check_out_before: 99999 }) }))).toBeNull();
  });
  it("blocked storage never throws", () => {
    const bad = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); } };
    expect(() => saveNotificationPrefs("u1", prefs, bad)).not.toThrow();
    expect(readNotificationPrefs("u1", bad)).toBeNull();
    expect(() => saveNotificationPrefs("u1", prefs, null)).not.toThrow();
    expect(readNotificationPrefs("u1", null)).toBeNull();
  });
});
