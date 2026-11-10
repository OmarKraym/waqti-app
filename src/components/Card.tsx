import type { HTMLAttributes, ReactNode } from "react";

/** A surface: padded card (default) or a "group" that holds rows edge to edge. */
export function Card({ as: Tag = "div", flush, className, children, ...rest }: Omit<HTMLAttributes<HTMLElement>, "className"> & {
  as?: "div" | "section" | "article";
  /** Rows edge to edge (no padding, clipped corners). */
  flush?: boolean;
  className?: string;
  children: ReactNode;
}) {
  return <Tag {...rest} className={[flush ? "group" : "card", className].filter(Boolean).join(" ")}>{children}</Tag>;
}
