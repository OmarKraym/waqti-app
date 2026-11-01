import { useEffect, useMemo, useState } from "react";
import type { SessionUser } from "../lib/api";
import { api } from "../lib/client";
import { loginToggle, setLoginEnabled, supportsPlatformAuthenticator } from "../lib/biometric";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { browserStorage, loadQueue, pendingOf } from "../lib/offlineQueue";
import type { AttendanceState } from "../lib/types";
import { AppBar, Icon, Modal } from "./ui";

/** What the profile shows; it comes from the today screen's data (nothing extra is fetched). */
export type ProfileInfo = Pick<AttendanceState, "employee" | "company" | "biometric">;

/** "Are you sure you want to sign out?" — the one place sign-out is confirmed. */
export function ConfirmSignOut({ user, onCancel }: { user: SessionUser; onCancel: () => void }) {
  const waiting = useMemo(() => {
    const storage = browserStorage();
    return storage ? pendingOf(loadQueue(storage, user.id)).length : 0;
  }, [user.id]);
  return (
    <Modal title="تسجيل الخروج" onClose={onCancel}>
      <p className="modal-text">
        {waiting > 0
          ? `لديك ${waiting} تسجيل لم يُرسل بعد. سيبقى محفوظًا على هذا الجهاز ويُرسل عند دخولك مرة أخرى. هل تريد الخروج من حسابك؟`
          : "هل تريد الخروج من حسابك؟"}
      </p>
      <div className="modal-actions">
        <button className="btn ghost" onClick={onCancel}>البقاء في التطبيق</button>
        <button className="btn danger" onClick={() => void api.signOut()}><Icon name="signOut" />تأكيد الخروج</button>
      </div>
    </Modal>
  );
}

/** "Sign in with fingerprint": one switch, enforced by the server. */
function BiometricLogin({ biometric, online, onChanged }: {
  biometric: ProfileInfo["biometric"] | undefined; online: boolean; onChanged: (enabled: boolean) => void;
}) {
  const [supported, setSupported] = useState(true);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ kind: "success" | "error"; text: string } | null>(null);
  useEffect(() => { supportsPlatformAuthenticator().then(setSupported); }, []);
  const toggle = loginToggle(biometric, supported);

  async function flip(next: boolean) {
    if (busy) return;
    setBusy(true);
    setMessage(null);
    try {
      const now = await setLoginEnabled(api, next);
      onChanged(now);
      setMessage({ kind: "success", text: now ? "تم تشغيل الدخول بالبصمة." : "تم إيقاف الدخول بالبصمة. ستدخل بكلمة المرور." });
    } catch (e) {
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      if (err.code === "not_authenticated") void api.signOut();
      setMessage({ kind: "error", text: err.code === "network" ? "تعذّر الاتصال بالخادم. تحقق من الإنترنت وحاول مرة أخرى." : ERROR_TEXT[err.code] });
    } finally {
      setBusy(false);
    }
  }

  const detail =
    toggle.kind === "off_by_company" ? "غير مطلوبة في شركتك."
    : toggle.kind === "needs_device" ? "سجّل بصمتك أولًا عند أول تسجيل حضور."
    : toggle.on ? "تدخل بالبصمة بدل كلمة المرور بعد تسجيل الخروج."
    : "الدخول بكلمة المرور فقط.";
  return (
    <section className="group bio-card" aria-label="الدخول بالبصمة">
      <div className="bio-row">
        <span className="bio-ico" aria-hidden="true"><Icon name="fingerprint" /></span>
        <div className="bio-text">
          <span className="bio-title" id="bio-title">الدخول بالبصمة</span>
          <span className="bio-detail">{detail}</span>
        </div>
        {toggle.kind === "switch" && (
          <button
            type="button" role="switch" className={`switch${toggle.on ? " on" : ""}`}
            aria-checked={toggle.on} aria-labelledby="bio-title"
            disabled={busy || !online || (!toggle.on && !toggle.canTurnOn)}
            onClick={() => flip(!toggle.on)}
          >
            <span className="switch-knob" aria-hidden="true" />
          </button>
        )}
      </div>
      {toggle.kind === "switch" && !toggle.on && !toggle.canTurnOn && (
        <p className="bio-note">هذا الهاتف لا يدعم البصمة، فلا يمكن تشغيلها منه.</p>
      )}
      {toggle.kind === "switch" && !online && <p className="bio-note">يلزم اتصال بالإنترنت لتغيير هذا الإعداد.</p>}
      {busy && toggle.kind === "switch" && !toggle.on && <p className="bio-note" role="status">أكّد بصمتك على هذا الهاتف…</p>}
      {message && <p className={`bio-note ${message.kind}`} role={message.kind === "error" ? "alert" : "status"}>{message.text}</p>}
    </section>
  );
}

export function Profile({ user, info, online, onBack, onSignOut, onLoginChanged }: {
  user: SessionUser; info: ProfileInfo | null; online: boolean; onBack: () => void; onSignOut: () => void;
  /** The fingerprint sign-in switch changed on the server. */
  onLoginChanged: (enabled: boolean) => void;
}) {
  const name = info?.employee.full_name ?? user.email ?? "";
  return (
    <div className="app">
      <AppBar title="حسابي" onBack={onBack} />
      <main className="container profile">
        <section className="profile-head">
          <span className="avatar" aria-hidden="true"><Icon name="user" /></span>
          <h2 className="profile-name">{name}</h2>
          {info?.employee.employee_number && <p className="profile-sub">رقم الموظف <span dir="ltr">{info.employee.employee_number}</span></p>}
        </section>

        <section className="group" aria-label="بيانات الحساب">
          <dl className="info-list">
            {info && (<div><dt>الشركة</dt><dd>{info.company.name}</dd></div>)}
            {user.email && (<div><dt>البريد</dt><dd dir="ltr">{user.email}</dd></div>)}
          </dl>
        </section>

        <BiometricLogin biometric={info?.biometric} online={online} onChanged={onLoginChanged} />

        <button className="btn danger-soft block" onClick={onSignOut}><Icon name="signOut" />تسجيل الخروج</button>
      </main>
    </div>
  );
}
