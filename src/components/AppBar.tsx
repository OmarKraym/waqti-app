import type { ReactNode } from "react";
import { IconButton } from "./IconButton";

/** The same bar on every screen (design 2026-11): optional back arrow, title with an optional line under it, one action at the end. */
export function AppBar({ title, sub, lead, onBack, backDisabled, action, className }: {
  title: ReactNode;
  /** A short muted line under the title. */
  sub?: ReactNode;
  lead?: ReactNode;
  onBack?: () => void;
  backDisabled?: boolean;
  action?: ReactNode;
  className?: string;
}) {
  return (
    <header className={`appbar${className ? ` ${className}` : ""}`}>
      <div className="appbar__lead">
        {onBack && (
          <IconButton icon="back" label="رجوع" onClick={onBack} disabled={backDisabled} />
        )}
        {lead}
        <div className="appbar__titles">
          <h1 className="appbar__title u-truncate">{title}</h1>
          {sub && <p className="appbar__sub u-truncate">{sub}</p>}
        </div>
      </div>
      {action}
    </header>
  );
}
