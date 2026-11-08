import { useEffect, useState, type FormEvent } from "react";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { takeSignoutReason } from "../lib/signoutReason";
import { clearDeviceHint, readDeviceHint } from "../lib/bioDevice";
import { readLastEmail, saveLastEmail } from "../lib/localSettings";
import { loginWithFingerprint, supportsPlatformAuthenticator } from "../lib/biometric";
import { useInstall } from "./hooks";
import { InstallLine } from "./InstallLine";
import { Icon, PasswordInput } from "./ui";

export function Login() {
  const [email, setEmail] = useState(() => readLastEmail() ?? "");
  const [prefilled] = useState(() => readLastEmail() !== null);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  // Signed out by the app (another phone, or an unbind): say why, once.
  const [error, setError] = useState<string | null>(() => {
    const why = takeSignoutReason();
    return why ? ERROR_TEXT[why] : null;
  });
  // After sign-out the phone still knows its registered fingerprint: offer it (the password form stays below).
  const [bioReady, setBioReady] = useState(false);
  // Installing the app is offered here, before sign-in (the browser's prompt is captured at start-up, see lib/install.ts).
  const install = useInstall();

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
      } else if (code === "login_disabled") {
        clearDeviceHint(); // the employee switched it off in the profile: the button goes away
        setBioReady(false);
        setError(ERROR_TEXT.login_disabled);
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
      saveLastEmail(email);
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
            name="email"
            id="email"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>

        <label className="field">
          <span>كلمة المرور</span>
          <PasswordInput
            autoComplete="current-password"
            name="password"
            autoFocus={prefilled && !readDeviceHint()}
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
        {install.view !== "hidden" && <InstallLine kind={install.view} onInstall={install.install} onClose={install.close} />}
      </form>
    </main>
  );
}
