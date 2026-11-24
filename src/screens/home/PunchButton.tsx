import { actionLabel } from "../../lib/attendance";
import type { AttendanceAction } from "../../lib/types";
import { Icon } from "../../components";

/** The screen's main action: a pill above the tab bar (design: dark green "check in" with a fingerprint, red "check out"),
 *  with one line saying what is happening. */
export function PunchButton({ action, fingerprint, sub, working, disabled, onTap }: {
  action: AttendanceAction;
  /** The company requires the fingerprint: the icon says so. */
  fingerprint: boolean;
  sub: string | null;
  working: boolean;
  disabled: boolean;
  onTap: () => void;
}) {
  return (
    <button
      className={`punch punch--${action === "check_in" ? "in" : "out"}`}
      onClick={onTap}
      disabled={disabled /* a stale tap is still safe: the server checks expected_action */}
      aria-busy={working}
    >
      <span className="punch__icon" aria-hidden="true">
        <Icon name={fingerprint || action === "check_in" ? "fingerprint" : "leave"} />
      </span>
      <span className="punch__text">
        <span className="punch__label">{actionLabel(action)}</span>
        <span className="punch__sub">{sub}</span>
      </span>
    </button>
  );
}
