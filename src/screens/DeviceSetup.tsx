import { useState } from "react";
import { registerDevice } from "../lib/biometric";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { Banner, Icon } from "./ui";

/** Shown in place of the punch button until this phone is registered (company requires the fingerprint). */
export function DeviceSetup({ onDone }: { onDone: () => void }) {
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
      <Icon name="phone" className="pad-icon" />
      <h2 id="device-setup-title" className="pad-title">سجّل بصمتك لهذا الجهاز</h2>
      <p className="muted">
        يُسجَّل هاتف واحد فقط لحسابك. لتغييره لاحقًا اطلب من الإدارة إلغاء القديم.
      </p>
      {error && <Banner kind="error" onClose={() => setError(null)}>{error}</Banner>}
      <button className="btn primary block" onClick={register} disabled={busy} aria-busy={busy}>
        {busy ? "جارٍ التسجيل…" : "تسجيل البصمة"}
      </button>
    </section>
  );
}
