import type { ReactNode } from "react";

/** What a list says when it has nothing yet: one calm line in a dashed box (no full stop). */
export function EmptyState({ children }: { children: ReactNode }) {
  return <p className="u-muted empty">{children}</p>;
}
