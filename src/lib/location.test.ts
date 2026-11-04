import { describe, expect, it } from "vitest";
import { geoGrantedBefore, gpsPrompt, markGeoGranted, readLocation } from "./location";

describe("gpsPrompt", () => {
  it("asks for GPS when no position was read", () => {
    for (const kind of ["denied", "timeout", "unavailable", "unsupported"] as const) {
      expect(gpsPrompt({ kind }), kind).toMatch(/GPS/);
    }
  });
  it("says nothing when a position was read or none is wanted", () => {
    expect(gpsPrompt({ kind: "ok", lat: 32.9, lng: 13.2, accuracy_m: 10 })).toBeNull();
    expect(gpsPrompt({ kind: "not_requested" })).toBeNull();
  });
  it("tells a blocked permission apart from a switched-off GPS", () => {
    expect(gpsPrompt({ kind: "denied" })).not.toBe(gpsPrompt({ kind: "unavailable" }));
  });
});

describe("location allowed once on this phone", () => {
  const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) }; };
  it("is remembered after the first position", async () => {
    const st = mem();
    expect(geoGrantedBefore(st)).toBe(false);
    const geo = { getCurrentPosition: (ok: PositionCallback) => ok({ coords: { latitude: 32.9, longitude: 13.2, accuracy: 8 } } as GeolocationPosition) } as unknown as Geolocation;
    await readLocation("record", geo, st);
    expect(geoGrantedBefore(st)).toBe(true);
  });
  it("after that, 'denied' means the GPS is off: a short 'switch it on' message, not the permission steps", () => {
    const t = gpsPrompt({ kind: "denied" }, true);
    expect(t).toMatch(/GPS/);
    expect(t).not.toMatch(/ممنوع|الإعدادات/);
    expect(t).toBe(gpsPrompt({ kind: "unavailable" }, true));
  });
  it("blocked storage never throws", () => {
    const bad = { getItem: () => { throw new Error("x"); }, setItem: () => { throw new Error("x"); } };
    expect(geoGrantedBefore(bad)).toBe(false);
    expect(() => markGeoGranted(bad)).not.toThrow();
  });
});
