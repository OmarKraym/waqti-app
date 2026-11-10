import type { ButtonHTMLAttributes } from "react";
import { Icon, type IconName } from "./Icon";

/** A round 44 px button with one icon and no text: it must have a spoken name. */
export function IconButton({ icon, label, ...rest }: Omit<ButtonHTMLAttributes<HTMLButtonElement>, "className" | "children" | "aria-label"> & {
  icon: IconName;
  label: string;
}) {
  return (
    <button type="button" {...rest} className="icon-btn" aria-label={label}>
      <Icon name={icon} />
    </button>
  );
}
