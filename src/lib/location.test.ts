import { describe, expect, it } from "vitest";
import { gpsPrompt } from "./location";

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
