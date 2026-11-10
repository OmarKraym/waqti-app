import type { ReactNode } from "react";
import { Button } from "./Button";
import { Modal } from "./Modal";

/**
 * «Are you sure?» in the app's own dialog (instead of window.confirm): focus is trapped, Esc and a tap outside cancel,
 * focus goes back where it was. The safe choice comes first, so it gets the focus; a destructive confirm is red.
 */
export function ConfirmDialog({ title, children, confirmLabel, cancelLabel = "تراجع", danger, busy, onConfirm, onCancel }: {
  title: string;
  children: ReactNode;
  confirmLabel: string;
  cancelLabel?: string;
  danger?: boolean;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <Modal title={title} onClose={onCancel} busy={busy}>
      <p className="modal__text">{children}</p>
      <div className="modal__actions">
        <Button variant="quiet" block onClick={onCancel} disabled={busy}>{cancelLabel}</Button>
        <Button variant={danger ? "danger" : "primary"} block onClick={onConfirm} loading={busy}>{confirmLabel}</Button>
      </div>
    </Modal>
  );
}
