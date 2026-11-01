// After a late check-in the app offers a late-arrival justification (a dialog) if it can still be requested.
// This file only decides WHETHER to offer and prepares the form. Whether the arrival really is late is the
// SERVER's call (the preview answers "not_late" or a number of minutes), so shifts and days off stay on the server.
import { emptyDraft, localDate, localHM, permissionLeft, type Draft } from "./requests";
import type { PermissionUsage, RequestsOverview } from "./types";

export interface LateCandidate {
  ptype: PermissionUsage;
  /** The request form, filled in: type "late arrival", today, arrival time = the time of the punch. */
  draft: Draft;
}

export function lateCandidate(overview: RequestsOverview, punchIso: string, timeZone: string): LateCandidate | null {
  const ptype = overview.permission_types.find((p) => p.mode === "late_arrival");
  if (!ptype) return null;
  const left = permissionLeft(ptype);
  if (left !== null && left < 1) return null; // the month's allowance is used up
  const day = localDate(punchIso, timeZone);
  const already = overview.requests.some(
    (r) => r.type === "permission" && r.permission_type_id === ptype.id
      && (r.status === "pending" || r.status === "approved") && localDate(r.start_at, timeZone) === day,
  );
  if (already) return null;
  return {
    ptype,
    draft: { ...emptyDraft(day, ptype), type: "permission", permission_type_id: ptype.id, permission_mode: "late_arrival", date: day, to: localHM(punchIso, timeZone) },
  };
}
