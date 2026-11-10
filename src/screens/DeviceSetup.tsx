import { useState } from "react";
import { registerDevice } from "../lib/biometric";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { Banner, Icon } from "../components";

/** Shown in place of the punch button until this phone is registered (company requires the fingerprint). */
export function DeviceSetup({ onDone, onSignOut }: { onDone: () => void; onSignOut?: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function register() {
    setBusy(true);
    setError(null);
    try {
      await registerDevice(api);
      onDone();
    } catch (e) {
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      setError(ERROR_TEXT[err.code]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card pad device-setup" aria-labelledby="device-setup-title">
      <Icon name="phone" className="pad__icon" />
      <h2 id="device-setup-title" className="pad__title">سجّل بصمتك لهذا الجهاز</h2>
      <p className="u-muted">
        يُسجَّل هاتف واحد فقط لحسابك. لتغييره لاحقًا اطلب من الإدارة إلغاء القديم.
      </p>
      {error && <Banner kind="error" onClose={() => setError(null)}>{error}</Banner>}
      <button className="btn btn--primary btn--block" onClick={register} disabled={busy} aria-busy={busy}>
        {busy ? "جارٍ التسجيل…" : "تسجيل البصمة"}
      </button>
      {onSignOut && (
        <button className="btn btn--quiet btn--block" onClick={onSignOut} disabled={busy}>تسجيل الخروج</button>
      )}
    </section>
  );
}
