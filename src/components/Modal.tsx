import { useEffect, useRef, type ReactNode } from "react";

/**
 * A centred question on a dimmed screen. Esc or a tap outside closes it (onClose); the first button is focused
 * (put the safe choice first in `children`), and focus goes back to where it was when it closes.
 */
export function Modal({ title, children, onClose, busy, sheet }: {
  title: string;
  /** Slide up from the bottom of the screen instead of sitting in the middle. */
  sheet?: boolean;
  children: ReactNode;
  onClose: () => void;
  /** While something is being sent: Esc and the backdrop do nothing. */
  busy?: boolean;
}) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const before = document.activeElement as HTMLElement | null;
    box.current?.querySelector<HTMLElement>("button:not(:disabled)")?.focus();
    return () => before?.focus?.();
  }, []);
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === "Escape" && !busy) { e.stopPropagation(); onClose(); return; }
    if (e.key !== "Tab") return;
    const items = [...(box.current?.querySelectorAll<HTMLElement>("button:not(:disabled), [href], input, select, textarea") ?? [])];
    if (items.length === 0) return;
    const first = items[0], last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  };
  return (
    <div className={`modal-backdrop${sheet ? " modal-backdrop--sheet" : ""}`} onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title" ref={box} onKeyDown={onKey}>
        <h2 id="modal-title" className="modal__title">{title}</h2>
        {children}
      </div>
    </div>
  );
}
