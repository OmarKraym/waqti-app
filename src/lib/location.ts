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

/**
 * What to tell the employee when the phone gave no position. null = a position was read (or none is wanted).
 * The punch is NOT sent in that case, so no fingerprint and no server call is wasted.
 */
export function gpsPrompt(reading: LocationReading): string | null {
  switch (reading.kind) {
    case "denied":
      return "الموقع ممنوع لهذا التطبيق. اسمح له بالوصول إلى الموقع من إعدادات الهاتف أو المتصفح، وشغّل GPS، ثم اضغط مرة أخرى.";
    case "timeout":
      return "لم نصل إلى موقعك. تأكد أن GPS مشغّل وانتقل إلى مكان مفتوح، ثم اضغط مرة أخرى.";
    case "unavailable":
    case "unsupported":
      return "شغّل GPS (خدمة الموقع) في هاتفك، ثم اضغط مرة أخرى.";
    default:
      return null;
  }
}
