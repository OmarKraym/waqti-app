import type {
  AttendanceState,
  Decision,
  InboxItem,
  NewRequest,
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
  signOut(): Promise<void>;
  changeTemporaryPassword(newPassword: string): Promise<void>;
  getAttendanceState(): Promise<AttendanceState>;
  punch(input: PunchInput): Promise<PunchResult>;
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
}

export interface SessionUser {
  id: string;
  email: string | null;
  mustChangePassword: boolean;
}
