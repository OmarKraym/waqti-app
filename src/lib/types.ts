// Shapes returned by the server. See docs/API_CONTRACT.md.

export type AttendanceAction = "check_in" | "check_out";

/** How location is handled for this employee (set by the company admin). */
export type LocationPolicy = "geofence" | "record" | "none";

/** Geofence policy only: what happens outside the approved area. */
export type OutsideAction = "flag" | "reject";

/** Final location result, decided by the SERVER. */
export type LocationStatus =
  | "inside"        // geofence: confirmed inside the area
  | "outside"       // geofence: confirmed outside the area
  | "recorded"      // record policy: location saved, no boundary
  | "unavailable"   // no reading (denied, timeout, unsupported)
  | "inaccurate"    // reading too weak to decide
  | "not_requested";// "none" policy

export interface AttendanceEvent {
  id: string;
  action: AttendanceAction;
  server_time: string; // ISO timestamp from the server clock
  location_status: LocationStatus;
  needs_review: boolean;
}

export interface AttendanceState {
  employee: { full_name: string; employee_number: string | null };
  company: { name: string; timezone: string };
  next_action: AttendanceAction;
  open_session: { started_at: string } | null;
  location_policy: LocationPolicy;
  outside_action: OutsideAction;
  /** Readings with accuracy worse than this (meters) count as "inaccurate". */
  max_accuracy_m: number;
  recent_events: AttendanceEvent[];
  server_time: string;
}

/** What the device managed to read. The server makes the final decision. */
export type LocationReading =
  | { kind: "ok"; lat: number; lng: number; accuracy_m: number }
  | { kind: "denied" }
  | { kind: "unavailable" }
  | { kind: "timeout" }
  | { kind: "unsupported" }
  | { kind: "not_requested" };

export interface PunchInput {
  request_id: string;           // idempotency key: the same key never records twice
  expected_action: AttendanceAction;
  reading: LocationReading;
}

export interface PunchResult {
  event_id: string;
  action: AttendanceAction;
  server_time: string;
  location_status: LocationStatus;
  needs_review: boolean;
  /** true = the server had already processed this request_id (safe retry). */
  duplicate: boolean;
}
