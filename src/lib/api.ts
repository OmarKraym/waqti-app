import type { AttendanceState, PunchInput, PunchResult } from "./types";

/** Everything the screens need from the server. Real and fake versions implement it. */
export interface WaqtiApi {
  getSessionUser(): Promise<SessionUser | null>;
  onAuthChange(cb: () => void): () => void;
  signIn(email: string, password: string): Promise<void>;
  signOut(): Promise<void>;
  changeTemporaryPassword(newPassword: string): Promise<void>;
  getAttendanceState(): Promise<AttendanceState>;
  punch(input: PunchInput): Promise<PunchResult>;
}

export interface SessionUser {
  id: string;
  email: string | null;
  mustChangePassword: boolean;
}
