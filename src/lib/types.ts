import type { BiometricState } from "./biometric";
import type { PunchWindow } from "./punchWindow";
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
  /** Phase 20: the admin added this movement (a forgotten check-in or check-out). Absent from an older server. */
  by_admin?: boolean;
}

export interface AttendanceState {
  employee: { full_name: string; employee_number: string | null };
  company: { name: string; timezone: string };
  next_action: AttendanceAction;
  /** Phase 13: no check-in today but a check-out may still be recorded (he forgot to check in). */
  can_check_out_without_in?: boolean;
  /** Phase 14: the check-in window is over and only the check-out window is open: the main button is "check out". */
  forgot_check_in?: boolean;
  open_session: { started_at: string } | null;
  location_policy: LocationPolicy;
  outside_action: OutsideAction;
  /** Readings with accuracy worse than this (meters) count as "inaccurate". */
  max_accuracy_m: number;
  recent_events: AttendanceEvent[];
  server_time: string;
  /** Signed server-time token. An offline punch can never be dated before it (see API_CONTRACT). */
  time_token: string;
  /** When the next punch is allowed (phase 8a). */
  punch_window: PunchWindow;
  /** Fingerprint policy of the company and whether this account has a registered device (phase 8b). */
  biometric: BiometricState;
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
  /** "ticket" (fingerprint done, or not required) or "unsupported" (this phone cannot; flagged for review). */
  biometric?: "ticket" | "unsupported";
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
  /** Phase 13: a check-out saved without a check-in (flagged for review). */
  missing_checkin?: boolean;
  /** Phase 15: an approved leave covers today. The punch is saved; the manager decides about the leave. */
  on_approved_leave?: boolean;
  /** true = the server had already processed this request_id (safe retry). */
  duplicate: boolean;
  /** Fresh signed server-time token. */
  time_token?: string;
}

/**
 * Phase 19c: what the server says about ONE check-in that was just saved (`employee_late_status`).
 * `reason`: offer | not_check_in | day_off | not_first | not_late | within_grace | no_type | already | no_balance |
 * too_long | outside_window. Only `offer` means "offer a late-arrival justification"; any other value (also one added
 * later) means no offer. See docs/API_CONTRACT.md §5.
 */
export interface LateStatus {
  event_id: string;
  /** Minutes after the shift start, rounded up (0 = on time or early). */
  late_min: number;
  grace_min: number;
  /** Minutes that count after the grace period, by the company's rule. 0 = nothing counts. */
  chargeable_min: number;
  /** Expected deduction in minutes of pay by the company's policy; null = no policy covers the day / not applicable. */
  deduction_min: number | null;
  rule: "all_after_grace" | "beyond_grace" | string;
  /** Justifications left this month (null = no monthly limit, or the type was not reached). */
  remaining: number | null;
  offer: boolean;
  reason: string;
  /** The late-arrival permission type with this month's usage; null when the server did not get that far. */
  permission: PermissionUsage | null;
}

// ---------------------------------------------------------------- Requests (Phase 4). See docs/API_CONTRACT.md §4.

export type RequestType = "leave" | "permission" | "other";
export type LeaveType = "annual" | "sick" | "emergency" | "marriage" | "maternity" | "unpaid";
export type RequestStatus = "pending" | "approved" | "rejected" | "cancelled";
export type ApproverKind = "direct_manager" | "second_manager" | "specific_employee" | "hr";
export type StepStatus = "waiting" | "pending" | "approved" | "rejected" | "skipped" | "cancelled";

export interface ApprovalStep {
  step_order: number;
  kind: ApproverKind;
  status: StepStatus;
  approver_name: string | null;
  decided_at: string | null;
  note: string | null;
}

export interface RequestItem {
  id: string;
  type: RequestType;
  leave_type: LeaveType | null;
  /** Permissions only (phase 4d): the company's permission type. */
  permission_type_id?: string | null;
  permission_type?: string | null;
  status: RequestStatus;
  start_at: string;
  /** Exclusive end: a leave on 3-4 March ends at 5 March 00:00. */
  end_at: string;
  days: number | null;
  /** Days HR took from the balance when it differs from `days` (phase 18a). */
  charged_days?: number | null;
  /** Recorded by the server for a day the administration made annual leave (phase 18b). */
  company_leave_day_id?: string | null;
  minutes: number | null;
  reason: string | null;
  decision_note: string | null;
  decided_at: string | null;
  created_at: string;
  current_step: number | null;
  employee: { full_name: string; employee_number: string | null; department: string | null; job_title: string | null };
  steps: ApprovalStep[];
}

/** One leave type for one year. entitled/remaining null = not limited. */
export interface LeaveBalance {
  leave_type: LeaveType;
  entitled: number | null;
  used: number;
  pending: number;
  remaining: number | null;
  // Annual leave since phase 18a: earned day by day; `remaining` is what can be taken up to `as_of`.
  year?: number;
  /** Days earned up to as_of (with what was carried in). */
  earned?: number;
  /** Days carried in from last year. */
  carried?: number;
  used_outside?: number;
  as_of?: string;
}

/** How the time of a permission is entered (set per type by the company). */
export type PermissionMode =
  | "range"         // from - to (exit during the shift, work mission)
  | "late_arrival"  // arrival time; starts at the shift start (late justification)
  | "early_leave";  // exit time; ends at the shift end (final exit)

/** One permission type of the company, with what the employee used of it this month (pending counts). */
export interface PermissionUsage {
  id: string;
  name: string;
  mode: PermissionMode;
  max_per_month: number | null; // null = no limit
  max_minutes: number | null;   // per request; null = no limit
  days_back: number;            // how many days back it may be requested (0 = same day)
  days_ahead: number;
  month: string;                // YYYY-MM
  used: number;                 // approved requests this month
  pending: number;              // pending requests this month
}

export interface RequestsOverview {
  balances: LeaveBalance[];
  permission_types: PermissionUsage[];
  requests: RequestItem[];
  inbox_count: number;
  timezone: string;
  today: string; // YYYY-MM-DD in the company time zone
  /** Earliest day a leave may start (company rule). Missing = the server does not say (older database). */
  leave_earliest?: string;
}

export type NewRequest =
  | { type: "leave"; leave_type: LeaveType; start_date: string; end_date: string; reason: string | null }
  | { type: "permission"; permission_type_id: string; start_at: string | null; end_at: string | null; reason: string | null }
  | { type: "other"; start_date: string; end_date: string; reason: string };

/** What the server computed for a request without saving it (dry run). */
export interface RequestPreview {
  start_at: string;
  end_at: string;
  days: number | null;
  minutes: number | null;
  balance: LeaveBalance | null;
  permission: PermissionUsage | null;
  /** More than the balance (phase 18a): allowed with a reason, HR decides. */
  over_balance?: boolean;
}

export interface InboxItem extends RequestItem {
  approval_id: string;
  my_step: number;
  step_count: number;
  /** The requester's balance, NOT counting this request. */
  balance: LeaveBalance | null;
  permission: PermissionUsage | null;
}

export type Decision = "approve" | "reject";

// ---------------------------------------------------------------- Notifications (Phase 5)

export interface NotificationSettings {
  remind_check_in: boolean;
  check_in_before: number;   // minutes before the shift start (0 = at the start)
  remind_check_out: boolean;
  check_out_before: number;  // minutes before the shift end (0 = at the end)
  devices: number;           // devices of mine that receive notifications
}

// ---------------------------------------------------------------- Overtime (Phase 6)

export interface OvertimeItem {
  id: string;
  status: "assigned" | "cancelled";
  /** upcoming / now (running) / done / cancelled, decided by the server clock */
  phase: "upcoming" | "now" | "done" | "cancelled";
  start_at: string;
  end_at: string;
  minutes: number;
  task: string | null;
  employee: { id: string; full_name: string; employee_number: string | null; department: string | null };
  assigned_by: { id: string; full_name: string };
  employee_note: string | null;
  employee_noted_at: string | null;
  cancelled_at: string | null;
  cancelled_by_name: string | null;
  created_at: string;
  /** Minutes covered by his punches inside the window (null before it starts). */
  actual_minutes: number | null;
}

export interface TeamMember {
  id: string;
  full_name: string;
  employee_number: string | null;
  department: string | null;
  /** true = I am his direct manager; false = he is lower in my chain */
  direct: boolean;
}

export interface OvertimeOverview {
  mine: OvertimeItem[];
  team: TeamMember[];
  assigned_by_me: OvertimeItem[];
  limits: { day_minutes: number | null; month_minutes: number | null };
  timezone: string;
  today: string;
}

export interface OvertimeInput {
  employee_id: string;
  start_at: string;
  end_at: string;
  task: string | null;
}

export interface OvertimePreview {
  minutes: number;
  used_day: number;
  used_month: number;
  limit_day: number | null;
  limit_month: number | null;
  shift_start: string | null;
  shift_end: string | null;
}

/** "My data summary" (phase 16c). Only the parts the company allows are sent; a hidden part has no key at all. */
export interface ProfileSummary {
  employee?: {
    department?: string | null;
    job_title?: string | null;
    work_location_name?: string | null;
    hire_date?: string | null;
    birth_date?: string | null;
    gender?: string | null;
  };
  schedule?: { weekday: number; is_workday: boolean; start_time: string | null; end_time: string | null }[];
  salary?: { base_salary?: number; components?: { name: string; amount: number }[]; total?: number };
  leave?: { type: string; days: number; is_default: boolean }[];
}
