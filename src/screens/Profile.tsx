import { useCallback, useEffect, useMemo, useState } from "react";
import type { SessionUser } from "../lib/api";
import { api } from "../lib/client";
import { loginToggle, setLoginEnabled, supportsPlatformAuthenticator } from "../lib/biometric";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { browserStorage, loadQueue, pendingOf } from "../lib/offlineQueue";
import { THEME_CHOICES, THEME_HINT, THEME_LABEL, chooseTheme, currentChoice, type ThemeChoice } from "../lib/theme";
import { loadSummary, saveSummary, summaryGroups } from "../lib/profileSummary";
import { loadCalendar, offLabel } from "../lib/calendar";
import type { AttendanceState, ProfileSummary } from "../lib/types";
import { AppBar, Icon, Modal, Switch } from "./ui";

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

/** Light / dark / auto. Saved on this phone only. */
function ThemeCard() {
  const [choice, setChoice] = useState<ThemeChoice>(currentChoice);
  const pick = (next: ThemeChoice) => {
    setChoice(next);
    chooseTheme(next);
  };
  return (
    <section className="group theme-card" aria-labelledby="theme-title">
      <div className="theme-head">
        <span className="theme-ico" aria-hidden="true"><Icon name="contrast" /></span>
        <div className="bio-text">
          <span className="bio-title" id="theme-title">المظهر</span>
          <span className="theme-note">{THEME_HINT[choice]}</span>
        </div>
      </div>
      <div className="seg" role="radiogroup" aria-labelledby="theme-title">
        {THEME_CHOICES.map((c) => (
          <button key={c} type="button" role="radio" aria-checked={choice === c} className={`seg-btn${choice === c ? " on" : ""}`} onClick={() => pick(c)}>
            {THEME_LABEL[c]}
          </button>
        ))}
      </div>
    </section>
  );
}

/**
 * "My data summary": only what the company allows (the server leaves the rest out). The copy saved on this phone shows
 * at once and with no connection; it is replaced every time the profile opens online.
 */
function MySummary({ userId, online }: { userId: string; online: boolean }) {
  const [saved] = useState(() => loadSummary(userId));
  const [data, setData] = useState<ProfileSummary | null>(saved?.data ?? null);
  const [savedAt, setSavedAt] = useState<number | null>(saved?.saved_at_ms ?? null);
  const [state, setState] = useState<"loading" | "live" | "error">("loading");

  const load = useCallback(async () => {
    setState("loading");
    try {
      const fresh = await api.getProfileSummary();
      saveSummary(userId, fresh);
      setData(fresh);
      setSavedAt(null);
      setState("live");
    } catch (e) {
      if (e instanceof AppError && e.code === "not_authenticated") return void api.signOut();
      setState("error");
    }
  }, [userId]);
  useEffect(() => { void load(); }, [load, online]);

  const groups = data ? summaryGroups(data, new Date(), offLabel(loadCalendar(userId))) : [];
  if (data && groups.length === 0 && state !== "error") return null; // nothing allowed: no section at all
  return (
    <section className="summary" aria-labelledby="summary-title" aria-busy={state === "loading"}>
      <h3 id="summary-title" className="summary-title">ملخص بياناتي</h3>
      {!data && state === "loading" && <div className="group summary-skeleton" aria-hidden="true"><div /><div /><div /></div>}
      {!data && state === "error" && (
        <div className="group summary-empty">
          <p className="muted">{online ? "تعذّر عرض ملخص بياناتك الآن." : "يلزم اتصال بالإنترنت لعرض ملخص بياناتك."}</p>
          {online && <button className="btn ghost" onClick={() => void load()}>إعادة المحاولة</button>}
        </div>
      )}
      {data && state === "error" && savedAt !== null && (
        <p className="summary-stale">آخر تحديث {new Date(savedAt).toLocaleDateString("en-GB")} — {online ? "تعذّر التحديث الآن." : "لا يوجد اتصال."}</p>
      )}
      {groups.map((g) => (
        <section key={g.title} className="group" aria-label={g.title}>
          <h4 className="summary-group">{g.title}</h4>
          <dl className="info-list">
            {g.rows.map((r) => (
              <div key={r.label}>
                <dt>{r.label}</dt>
                <dd className={r.strong ? "strong" : undefined}>
                  <span dir={r.ltr ? "ltr" : undefined}>{r.value}</span>
                  {r.note && <span className="summary-note">{r.note}</span>}
                </dd>
              </div>
            ))}
          </dl>
        </section>
      ))}
    </section>
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
          <Switch
            checked={toggle.on} labelledBy="bio-title" onChange={flip}
            disabled={busy || !online || (!toggle.on && !toggle.canTurnOn)}
          />
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

        <MySummary userId={user.id} online={online} />

        <ThemeCard />

        <BiometricLogin biometric={info?.biometric} online={online} onChanged={onLoginChanged} />

        <button className="btn danger-soft block" onClick={onSignOut}><Icon name="signOut" />تسجيل الخروج</button>
      </main>
    </div>
  );
}
