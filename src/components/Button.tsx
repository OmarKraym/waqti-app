import type { ButtonHTMLAttributes, ReactNode } from "react";

export type ButtonVariant = "default" | "primary" | "ghost" | "quiet" | "danger" | "danger-soft" | "danger-text";
export type ButtonSize = "md" | "sm";

export type ButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, "className"> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Full width. */
  block?: boolean;
  /** The big «send» of a form: taller and rounder; disabled reads as «not ready yet». */
  send?: boolean;
  /** While a request runs: disabled and aria-busy, the label stays. */
  loading?: boolean;
  /** A layout hook of the screen (BEM element class), never a variant. */
  className?: string;
  children: ReactNode;
};

/** The one button of the app. Variants are a closed set; anything else is a screen's own element class. */
export function buttonClass({ variant = "default", size = "md", block, send, className }: Pick<ButtonProps, "variant" | "size" | "block" | "send" | "className">): string {
  return ["btn", variant !== "default" && `btn--${variant}`, size === "sm" && "btn--sm", block && "btn--block", send && "btn--send", className]
    .filter(Boolean).join(" ");
}

export function Button({ variant, size, block, send, loading, className, disabled, type = "button", children, ...rest }: ButtonProps) {
  return (
    <button {...rest} type={type} className={buttonClass({ variant, size, block, send, className })}
      disabled={disabled || loading} aria-busy={loading || undefined}>
      {children}
    </button>
  );
}
