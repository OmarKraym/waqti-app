import type { ButtonHTMLAttributes } from "react";
import { Icon, type IconName } from "./Icon";

/** A round 44 px button with one icon and no text: it must have a spoken name. `icon-btn--outlined`: on a hairline ring (header bell). */
export function IconButton({ icon, label, className, ...rest }: Omit<ButtonHTMLAttributes<HTMLButtonElement>, "children" | "aria-label"> & {
  icon: IconName;
  label: string;
}) {
  return (
    <button type="button" {...rest} className={`icon-btn${className ? ` ${className}` : ""}`} aria-label={label}>
      <Icon name={icon} />
    </button>
  );
}
