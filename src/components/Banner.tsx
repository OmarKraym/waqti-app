import type { ReactNode } from "react";
import { Icon } from "./Icon";

/** Dismissible message line (success / warning / error). */
export function Banner({ kind, children, onClose, className }: {
  kind: "success" | "warning" | "error";
  children: ReactNode;
  onClose?: () => void;
  className?: string;
}) {
  return (
    <div className={`banner banner--${kind}${className ? ` ${className}` : ""}`} role={kind === "success" ? "status" : "alert"}>
      <Icon name={kind === "success" ? "check" : "alert"} className="banner__icon" />
      <span className="banner__text">{children}</span>
      {onClose && (
        <button className="banner__close" aria-label="إغلاق" onClick={onClose}><Icon name="close" /></button>
      )}
    </div>
  );
}
