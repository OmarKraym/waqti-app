import { useState, type InputHTMLAttributes } from "react";
import { Icon } from "./Icon";

/** A password input with a button that shows or hides what was typed. */
export function PasswordInput(props: Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "dir">) {
  const [shown, setShown] = useState(false);
  return (
    <span className="password">
      <input {...props} type={shown ? "text" : "password"} dir="ltr" />
      <button
        type="button"
        className="password__eye"
        aria-label={shown ? "إخفاء كلمة المرور" : "إظهار كلمة المرور"}
        aria-pressed={shown}
        onClick={() => setShown((v) => !v)}
      >
        <Icon name={shown ? "eyeOff" : "eye"} />
      </button>
    </span>
  );
}
