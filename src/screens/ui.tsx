import type { ReactNode } from "react";

/** Line icons, 24 px grid, stroke = currentColor. */
const PATHS = {
  back: <path d="M9 5l7 7-7 7" />, // RTL: "back" points to the right
  plus: <path d="M12 5v14M5 12h14" />,
  signOut: <><path d="M10 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4" /><path d="M14 8l-4 4 4 4M10 12h10" /></>,
  pin: <><path d="M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0C18.5 15.4 12 21 12 21z" /><circle cx="12" cy="10" r="2.3" /></>,
  check: <><circle cx="12" cy="12" r="9" /><path d="M8.2 12.3l2.6 2.6 5-5.4" /></>,
  phone: <><rect x="7" y="3" width="10" height="18" rx="2.2" /><path d="M11 17.5h2" /></>,
  alert: <><circle cx="12" cy="12" r="9" /><path d="M12 7.5v5.5M12 16.4v.1" /></>,
  bell: <><path d="M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z" /><path d="M10 20.5a2 2 0 0 0 4 0" /></>,
  close: <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />,
} as const;

export type IconName = keyof typeof PATHS;

export function Icon({ name, className }: { name: IconName; className?: string }) {
  return (
    <svg className={`icon${className ? ` ${className}` : ""}`} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {PATHS[name]}
    </svg>
  );
}

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
      <div className="appbar-lead">
        {onBack && (
          <button className="icon-btn" onClick={onBack} disabled={backDisabled} aria-label="رجوع">
            <Icon name="back" />
          </button>
        )}
        {lead}
        <h1 className="appbar-title truncate">{title}</h1>
      </div>
      {action}
    </header>
  );
}

/** Dismissible message line (success / warning / error). */
export function Banner({ kind, children, onClose, className }: {
  kind: "success" | "warning" | "error";
  children: ReactNode;
  onClose?: () => void;
  className?: string;
}) {
  return (
    <div className={`banner ${kind}${className ? ` ${className}` : ""}`} role={kind === "success" ? "status" : "alert"}>
      <Icon name={kind === "success" ? "check" : "alert"} className="banner-icon" />
      <span className="banner-text">{children}</span>
      {onClose && (
        <button className="x" aria-label="إغلاق" onClick={onClose}><Icon name="close" /></button>
      )}
    </div>
  );
}
