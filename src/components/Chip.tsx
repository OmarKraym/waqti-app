import type { ReactNode } from "react";

export type ChipStatus = "pending" | "approved" | "rejected" | "cancelled" | "ot-upcoming" | "ot-now" | "ot-done" | "ot-cancelled";

/** A small status pill with a dot: the state of a request or an assignment. */
export function Chip({ status, children }: { status: ChipStatus; children: ReactNode }) {
  return <span className={`chip chip--${status}`}>{children}</span>;
}
