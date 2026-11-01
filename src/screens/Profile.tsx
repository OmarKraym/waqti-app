import { useMemo } from "react";
import type { SessionUser } from "../lib/api";
import { api } from "../lib/client";
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

function deviceText(b: ProfileInfo["biometric"] | undefined): string {
  if (!b || b.policy === "off") return "غير مطلوبة في شركتك";
  return b.has_device ? "مفعّلة على هذا الجهاز" : "غير مسجّلة بعد على هذا الجهاز";
}

export function Profile({ user, info, onBack, onSignOut }: {
  user: SessionUser; info: ProfileInfo | null; onBack: () => void; onSignOut: () => void;
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
            <div><dt>البصمة</dt><dd><Icon name="fingerprint" className="inline-icon" />{deviceText(info?.biometric)}</dd></div>
          </dl>
        </section>

        <button className="btn danger-soft block" onClick={onSignOut}><Icon name="signOut" />تسجيل الخروج</button>
      </main>
    </div>
  );
}
