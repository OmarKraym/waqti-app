import type {
  AttendanceState,
  Decision,
  InboxItem,
  NewRequest,
  NotificationSettings,
  OvertimeInput,
  OvertimeItem,
  OvertimeOverview,
  OvertimePreview,
  OfflinePunchInput,
  PunchInput,
  PunchResult,
  RequestItem,
  RequestPreview,
  RequestsOverview,
} from "./types";

/** Everything the screens need from the server. Real and fake versions implement it. */
export interface WaqtiApi {
  getSessionUser(): Promise<SessionUser | null>;
  onAuthChange(cb: () => void): () => void;
  signIn(email: string, password: string): Promise<void>;
  /** Opens the session with the one-time token the server gave after a valid fingerprint (no password). */
  signInWithToken(tokenHash: string): Promise<void>;
  signOut(): Promise<void>;
  changeTemporaryPassword(newPassword: string): Promise<void>;
  getAttendanceState(): Promise<AttendanceState>;
  punch(input: PunchInput): Promise<PunchResult>;
  /** Fingerprint steps (Edge Function "webauthn"): register this phone, get a ticket for one punch, or sign in. */
  webauthn(
    action: "register-options" | "register-verify" | "punch-options" | "punch-verify" | "login-options" | "login-verify",
    body?: object,
  ): Promise<unknown>;
  /** Sends a punch that was saved on the phone without internet. */
  punchOffline(input: OfflinePunchInput): Promise<PunchResult>;

  // ---- requests (Phase 4). All need a connection.
  getRequestsOverview(): Promise<RequestsOverview>;
  /** Checks a request with the server's rules and returns what it would be, without saving. */
  previewRequest(request: NewRequest): Promise<RequestPreview>;
  /** Saves the request. The same key never creates two requests (safe to retry after a lost reply). */
  submitRequest(key: string, request: NewRequest): Promise<RequestItem>;
  cancelRequest(id: string): Promise<RequestItem>;
  /** Requests waiting for MY decision (as a manager, a named approver, or the company admin). */
  getInbox(): Promise<InboxItem[]>;
  decide(approvalId: string, decision: Decision, note: string | null): Promise<RequestItem>;

  // ---- notifications (Phase 5)
  savePushSubscription(keys: { endpoint: string; p256dh: string; auth: string }): Promise<void>;
  deletePushSubscription(endpoint: string): Promise<void>;
  getNotificationSettings(): Promise<NotificationSettings>;
  setNotificationSettings(s: Omit<NotificationSettings, "devices">): Promise<NotificationSettings>;
  /** Sends a test notification to my devices (server-side, like the real ones). */
  testNotification(): Promise<void>;

  // ---- overtime (Phase 6)
  getOvertimeOverview(): Promise<OvertimeOverview>;
  /** Checks an assignment with the server's rules without saving it. */
  previewOvertime(input: OvertimeInput): Promise<OvertimePreview>;
  /** Saves it. The same key never creates two assignments. */
  assignOvertime(key: string, input: OvertimeInput): Promise<OvertimeItem>;
  cancelOvertime(id: string): Promise<OvertimeItem>;
  /** The assigned employee writes a note (e.g. he cannot do it). */
  noteOvertime(id: string, note: string): Promise<OvertimeItem>;
}

export interface SessionUser {
  id: string;
  email: string | null;
  mustChangePassword: boolean;
}
