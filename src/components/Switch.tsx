/**
 * The one switch of the app (role="switch"): same look and size on every screen. Put it in a `.switch-row`
 * (label first, switch last) or in any flex row. Name it with `labelledBy` (the id of its label) or `label`.
 */
export function Switch({ checked, onChange, disabled, labelledBy, label }: {
  checked: boolean;
  /** Gets the new value. */
  onChange: (next: boolean) => void;
  disabled?: boolean;
  labelledBy?: string;
  label?: string;
}) {
  return (
    <button
      type="button" role="switch" className={`switch${checked ? " is-active" : ""}`}
      aria-checked={checked} aria-labelledby={labelledBy} aria-label={label}
      disabled={disabled} onClick={() => onChange(!checked)}
    >
      <span className="switch__knob" aria-hidden="true" />
    </button>
  );
}
