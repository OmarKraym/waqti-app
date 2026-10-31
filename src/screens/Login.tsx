import { useState, type FormEvent } from "react";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";

export function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await api.signIn(email.trim(), password);
      // App switches screens on the auth change.
    } catch (err) {
      const code = err instanceof AppError ? err.code : "unknown";
      setError(code === "network" ? "تعذّر الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى." : ERROR_TEXT[code]);
      setBusy(false);
    }
  }

  return (
    <main className="auth-wrap">
      <form className="auth-card" onSubmit={submit} autoComplete="on" noValidate>
        <div className="auth-head">
          <img src={`${import.meta.env.BASE_URL}icons/icon.svg`} alt="" className="auth-logo" width={64} height={64} />
          <h1>وقتي</h1>
          <p className="muted">سجّل دخولك لتسجيل الحضور والانصراف</p>
        </div>

        <label className="field">
          <span>البريد الإلكتروني</span>
          <input
            type="email"
            dir="ltr"
            inputMode="email"
            autoComplete="username"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>

        <label className="field">
          <span>كلمة المرور</span>
          <input
            type="password"
            dir="ltr"
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>

        <p className="form-error" role="alert">{error}</p>

        <button className="btn primary block" type="submit" disabled={busy || !email || !password}>
          {busy ? "جارٍ الدخول…" : "تسجيل الدخول"}
        </button>
        <p className="auth-foot">ستبقى مسجّلًا على هذا الجهاز حتى تسجّل الخروج.</p>
      </form>
    </main>
  );
}
