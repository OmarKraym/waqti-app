import type { ReactNode } from "react";

/** A labelled form control: the label text above, the control (input, select, textarea, TimeField) under it. */
export function Field({ label, children, className }: { label: ReactNode; children: ReactNode; className?: string }) {
  return (
    <label className={["field", className].filter(Boolean).join(" ")}>
      <span>{label}</span>
      {children}
    </label>
  );
}
