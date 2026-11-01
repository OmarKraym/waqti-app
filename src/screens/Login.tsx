import { useEffect, useState, type FormEvent } from "react";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { clearDeviceHint, readDeviceHint } from "../lib/bioDevice";
import { loginWithFingerprint, supportsPlatformAuthenticator } from "../lib/biometric";
import { Icon } from "./ui";

export function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // After sign-out the phone still knows its registered fingerprint: offer it (the password form stays below).
  const [bioReady, setBioReady] = useState(false);

  useEffect(() => {
    let alive = true;
    if (readDeviceHint()) {
      supportsPlatformAuthenticator().then((ok) => {
        if (alive) setBioReady(ok);
      });
    }
    return () => {
      alive = false;
    };
  }, []);

  async function bioLogin() {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const signedIn = await loginWithFingerprint(api);
      if (!signedIn) setBusy(false); // cancelled the prompt: stay here, no message
      // otherwise the app switches screens on the auth change
    } catch (err) {
      const code = err instanceof AppError ? err.code : "unknown";
      if (code === "device_not_registered") {
        clearDeviceHint();
        setBioReady(false);
        setError("هذا الهاتف لم يعد مسجّلًا للبصمة. ادخل بكلمة المرور.");
      } else {
        setError(code === "network" ? "تعذّر الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى." : ERROR_TEXT[code]);
      }
      setBusy(false);
    }
  }

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
        </div>

        {bioReady && (
          <>
            <button className="btn primary block bio-login" type="button" onClick={bioLogin} disabled={busy}>
              <Icon name="fingerprint" />
              {busy ? "جارٍ التحقق…" : "ادخل بالبصمة"}
            </button>
            <p className="auth-or"><span>أو بكلمة المرور</span></p>
          </>
        )}

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

        <button className={`btn ${bioReady ? "" : "primary "}block`} type="submit" disabled={busy || !email || !password}>
          {busy ? "جارٍ الدخول…" : "تسجيل الدخول"}
        </button>
        <p className="auth-foot">ستبقى مسجّلًا على هذا الجهاز حتى تسجّل الخروج.</p>
      </form>
    </main>
  );
}
