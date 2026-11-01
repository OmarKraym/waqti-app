import type { LocationPolicy, LocationReading } from "./types";

const LOCATION_TIMEOUT_MS = 12_000;

/**
 * Reads the device location once, for one attendance tap.
 * - "none" policy: never asks the browser for location.
 * - Never throws: every failure becomes a reading kind, and the SERVER decides what it means.
 * - maximumAge: 0 so an old cached position is never sent as a fresh one.
 */
export function readLocation(policy: LocationPolicy, geo: Geolocation | undefined = globalThis.navigator?.geolocation): Promise<LocationReading> {
  if (policy === "none") return Promise.resolve({ kind: "not_requested" });
  if (!geo) return Promise.resolve({ kind: "unsupported" });

  return new Promise((resolve) => {
    geo.getCurrentPosition(
      (pos) =>
        resolve({
          kind: "ok",
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          accuracy_m: Math.round(pos.coords.accuracy),
        }),
      (err) => {
        if (err.code === err.PERMISSION_DENIED) resolve({ kind: "denied" });
        else if (err.code === err.TIMEOUT) resolve({ kind: "timeout" });
        else resolve({ kind: "unavailable" });
      },
      { enableHighAccuracy: true, timeout: LOCATION_TIMEOUT_MS, maximumAge: 0 },
    );
  });
}
