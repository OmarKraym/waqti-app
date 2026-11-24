import type { ReactNode } from "react";
import { Icon, type IconName } from "./Icon";

/** What a list says when it has nothing yet: an icon over one calm line on a card (design 2026-11; no full stop needed). */
export function EmptyState({ icon = "inbox", children }: { icon?: IconName; children: ReactNode }) {
  return (
    <div className="empty">
      <Icon name={icon} className="empty__icon" />
      <p>{children}</p>
    </div>
  );
}
