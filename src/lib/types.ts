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
  /** true = punched on the phone without internet and sent later. */
  recorded_offline?: boolean;
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
  /** Signed server-time token. An offline punch can never be dated before it (see API_CONTRACT). */
  time_token: string;
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

/** A punch made without internet, sent later. The server checks the phone clock against the token. */
export interface OfflinePunchInput extends PunchInput {
  time_token: string;
  /** Phone clock when the token was received (ISO). */
  token_device_time: string;
  /** Phone clock at the tap (ISO). */
  device_time: string;
  /** ms since the token on the monotonic clock, or null if the app was restarted since. */
  monotonic_ms: number | null;
  /** Phone clock when sending (ISO). */
  device_now: string;
}

export interface PunchResult {
  event_id: string;
  action: AttendanceAction;
  server_time: string;
  location_status: LocationStatus;
  needs_review: boolean;
  recorded_offline?: boolean;
  /** true = the server had already processed this request_id (safe retry). */
  duplicate: boolean;
  /** Fresh signed server-time token. */
  time_token?: string;
}
