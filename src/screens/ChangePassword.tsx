import { useEffect, useState, type FormEvent } from "react";
import { api } from "../lib/client";
import { saveLastEmail } from "../lib/localSettings";
import { AppError, ERROR_TEXT } from "../lib/errors";

// Same rules as the change-password Edge Function (the server checks them again).
function localCheck(p: string, confirm: string): string | null {
  if ([...p].length < 8) return ERROR_TEXT.password_too_short;
  if (new TextEncoder().encode(p).length > 72) return ERROR_TEXT.password_too_long;
  if (!/\p{L}/u.test(p) || !/\p{N}/u.test(p)) return ERROR_TEXT.password_too_weak;
  if (p !== confirm) return "كلمتا المرور غير متطابقتين.";
  return null;
}

export function ChangePassword({ email }: { email: string | null }) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  useEffect(() => { if (email) saveLastEmail(email); }, [email]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (busy) return;
    const problem = localCheck(password, confirm);
    if (problem) return setError(problem);
    setBusy(true);
    setError(null);
    try {
      await api.changeTemporaryPassword(password);
      // App moves to the home screen on the auth change.
    } catch (err) {
      const code = err instanceof AppError ? err.code : "unknown";
      if (code === "not_authenticated") {
        await api.signOut();
        return;
      }
      setError(code === "network" ? "تعذّر الاتصال بالخادم. لم يتم تغيير كلمة المرور، حاول مرة أخرى." : ERROR_TEXT[code]);
      setBusy(false);
    }
  }

  return (
    <main className="auth-wrap">
      <form className="auth-card" onSubmit={submit} noValidate>
        <div className="auth-head">
        <h1>تغيير كلمة المرور</h1>
        <p className="muted">
          هذا أول دخول لك. اختر كلمة مرور جديدة بدل المؤقتة.
          {email && (
            <>
              <br />
              <span dir="ltr">{email}</span>
            </>
          )}
        </p>
        </div>

        {/* Username for password managers (Android and iPhone) to save the new password for the right account.
            Visually hidden, NOT display:none / hidden: managers may ignore those. */}
        <input className="sr-only" type="email" name="email" id="email" autoComplete="username" value={email ?? ""}
               readOnly tabIndex={-1} aria-hidden="true" />

        <label className="field">
          <span>كلمة المرور الجديدة</span>
          <input type="password" dir="ltr" autoComplete="new-password" name="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        <label className="field">
          <span>تأكيد كلمة المرور</span>
          <input type="password" dir="ltr" autoComplete="new-password" name="confirm-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        </label>
        <p className="hint-line">8 أحرف على الأقل، وتحتوي على حرف ورقم.</p>

        <p className="form-error" role="alert">{error}</p>

        <button className="btn primary block" type="submit" disabled={busy}>
          {busy ? "جارٍ الحفظ…" : "حفظ كلمة المرور"}
        </button>
        <button className="btn quiet block" type="button" onClick={() => api.signOut()} disabled={busy}>
          تسجيل الخروج
        </button>
      </form>
    </main>
  );
}
