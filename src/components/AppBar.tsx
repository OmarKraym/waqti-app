import type { ReactNode } from "react";
import { IconButton } from "./IconButton";

/** The same bar on every screen: optional back arrow, title, one action at the end. */
export function AppBar({ title, lead, onBack, backDisabled, action, className }: {
  title: ReactNode;
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
        <h1 className="appbar__title u-truncate">{title}</h1>
      </div>
      {action}
    </header>
  );
}
