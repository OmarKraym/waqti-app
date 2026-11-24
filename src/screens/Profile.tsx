import { useCallback, useEffect, useMemo, useState } from "react";
import type { SessionUser } from "../lib/api";
import { api } from "../lib/client";
import { loginToggle, setLoginEnabled, supportsPlatformAuthenticator } from "../lib/biometric";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { browserStorage, loadQueue, pendingOf } from "../lib/offlineQueue";
import { THEME_CHOICES, THEME_HINT, THEME_LABEL, chooseTheme, currentChoice, type ThemeChoice } from "../lib/theme";
import { jobLine, loadSummary, saveSummary, summaryGroups } from "../lib/profileSummary";
import { loadCalendar, offLabel } from "../lib/calendar";
import type { AttendanceState, ProfileSummary } from "../lib/types";
import { AppBar, Banner, Icon, Modal, Switch, Button } from "../components";

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
      <p className="modal__text">
        {waiting > 0
          ? `لديك ${waiting} تسجيل لم يُرسل بعد. سيبقى محفوظًا على هذا الجهاز ويُرسل عند دخولك مرة أخرى. هل تريد الخروج من حسابك؟`
          : "هل تريد الخروج من حسابك؟"}
      </p>
      <div className="modal__actions">
        <Button variant="ghost" onClick={onCancel}>البقاء في التطبيق</Button>
        <Button variant="danger" onClick={() => void api.signOut()}><Icon name="signOut" />تأكيد الخروج</Button>
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
    <div className="list-row list-row--stack">
      <div className="list-row__main">
        <span className="list-row__icon" aria-hidden="true"><Icon name="contrast" /></span>
        <div className="list-row__text">
          <span className="list-row__title" id="theme-title">المظهر</span>
          <span className="list-row__sub">{THEME_HINT[choice]}</span>
        </div>
      </div>
      <div className="seg" role="radiogroup" aria-labelledby="theme-title">
        {THEME_CHOICES.map((c) => (
          <button key={c} type="button" role="radio" aria-checked={choice === c} className={`seg__btn${choice === c ? " is-active" : ""}`} onClick={() => pick(c)}>
            {THEME_LABEL[c]}
          </button>
        ))}
      </div>
    </div>
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
      <h3 id="summary-title" className="summary__title">ملخص بياناتي</h3>
      {!data && state === "loading" && <div className="group summary__skeleton" aria-hidden="true"><div /><div /><div /></div>}
      {!data && state === "error" && (
        <div className="group summary__empty">
          <p className="u-muted">{online ? "تعذّر عرض ملخص بياناتك الآن." : "يلزم اتصال بالإنترنت لعرض ملخص بياناتك."}</p>
          {online && <Button variant="ghost" onClick={() => void load()}>إعادة المحاولة</Button>}
        </div>
      )}
      {data && state === "error" && savedAt !== null && (
        <p className="summary__stale">آخر تحديث {new Date(savedAt).toLocaleDateString("en-GB")} — {online ? "تعذّر التحديث الآن." : "لا يوجد اتصال."}</p>
      )}
      {groups.map((g) => (
        <section key={g.title} className="group" aria-label={g.title}>
          <h4 className="summary__group">{g.title}</h4>
          <dl className="info-list">
            {g.rows.map((r) => (
              <div key={r.label}>
                <dt>{r.label}</dt>
                <dd className={r.strong ? "info-list__strong" : undefined}>
                  <span dir={r.ltr ? "ltr" : undefined}>{r.value}</span>
                  {r.note && <span className="summary__note">{r.note}</span>}
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
    <div className="list-row list-row--stack bio-card">
      <div className="list-row__main">
        <span className="list-row__icon" aria-hidden="true"><Icon name="fingerprint" /></span>
        <div className="list-row__text">
          <span className="list-row__title" id="bio-title">الدخول بالبصمة</span>
          <span className="list-row__sub">{detail}</span>
        </div>
        {toggle.kind === "switch" && (
          <Switch
            checked={toggle.on} labelledBy="bio-title" onChange={flip}
            disabled={busy || !online || (!toggle.on && !toggle.canTurnOn)}
          />
        )}
      </div>
      {toggle.kind === "switch" && !toggle.on && !toggle.canTurnOn && (
        <p className="bio-card__note">هذا الهاتف لا يدعم البصمة، فلا يمكن تشغيلها منه.</p>
      )}
      {toggle.kind === "switch" && !online && <p className="bio-card__note">يلزم اتصال بالإنترنت لتغيير هذا الإعداد.</p>}
      {busy && toggle.kind === "switch" && !toggle.on && <p className="bio-card__note" role="status">أكّد بصمتك على هذا الهاتف…</p>}
      {message && <p className={`bio-card__note bio-card__note--${message.kind}`} role={message.kind === "error" ? "alert" : "status"}>{message.text}</p>}
    </div>
  );
}

export function Profile({ user, info, online, onBack, onSignOut, onLoginChanged, setupMissing = false, onOpenSetup, onOpenNotifications }: {
  user: SessionUser; info: ProfileInfo | null; online: boolean; onBack: () => void; onSignOut: () => void;
  /** Location or notifications are not set up on this phone (shown at the bottom of the page, never on Home). */
  setupMissing?: boolean; onOpenSetup?: () => void;
  /** «التنبيهات» row: opens reminders and holidays. */
  onOpenNotifications?: () => void;
  /** The fingerprint sign-in switch changed on the server. */
  onLoginChanged: (enabled: boolean) => void;
}) {
  const name = info?.employee.full_name ?? user.email ?? "";
  const job = jobLine(loadSummary(user.id)?.data);
  return (
    <div className="app">
      <AppBar title="الملف الشخصي" onBack={onBack} />
      <main className="container profile">
        <section className="card profile-head" aria-label="بيانات الموظف">
          <span className="avatar avatar--lg" aria-hidden="true">{name.trim().charAt(0) || <Icon name="user" />}</span>
          <div className="profile-head__text">
            <h2 className="profile-head__name">{name}</h2>
            {job && <p className="profile-head__sub">{job}</p>}
            {info?.employee.employee_number && <span className="code" dir="ltr">{info.employee.employee_number}</span>}
          </div>
        </section>

        <section className="settings" aria-labelledby="account-title">
          <h3 id="account-title" className="settings__title">الحساب</h3>
          <div className="group">
            {info && (
              <div className="list-row">
                <div className="list-row__main">
                  <span className="list-row__icon" aria-hidden="true"><Icon name="work" /></span>
                  <div className="list-row__text"><span className="list-row__title">الشركة</span><span className="list-row__sub">{info.company.name}</span></div>
                </div>
              </div>
            )}
            {user.email && (
              <div className="list-row">
                <div className="list-row__main">
                  <span className="list-row__icon" aria-hidden="true"><Icon name="mail" /></span>
                  <div className="list-row__text"><span className="list-row__title">البريد</span><span className="list-row__sub" dir="ltr">{user.email}</span></div>
                </div>
              </div>
            )}
          </div>
        </section>

        <MySummary userId={user.id} online={online} />

        <section className="settings" aria-labelledby="prefs-title">
          <h3 id="prefs-title" className="settings__title">تفضيلات التطبيق</h3>
          <div className="group">
            <div className="list-row">
              <div className="list-row__main">
                <span className="list-row__icon" aria-hidden="true"><Icon name="language" /></span>
                <div className="list-row__text"><span className="list-row__title">اللغة</span></div>
              </div>
              <span className="list-row__value">العربية</span>
            </div>
            {onOpenNotifications && (
              <button type="button" className="list-row list-row--link" onClick={onOpenNotifications}>
                <span className="list-row__main">
                  <span className="list-row__icon" aria-hidden="true"><Icon name="bellActive" /></span>
                  <span className="list-row__text">
                    <span className="list-row__title">التنبيهات</span>
                    <span className="list-row__sub">تذكير الحضور والانصراف والعطل الرسمية</span>
                  </span>
                </span>
                <Icon name="chevron" className="list-row__chevron" />
              </button>
            )}
            <ThemeCard />
            <BiometricLogin biometric={info?.biometric} online={online} onChanged={onLoginChanged} />
          </div>
        </section>

        {setupMissing && onOpenSetup && (
          <Banner kind="warning">
            هاتفك لم يُجهَّز بالكامل (الموقع أو الإشعارات). قد لا يصلك تذكير البصمة.{" "}
            <button className="link-btn" onClick={onOpenSetup}>إكمال الإعداد</button>
          </Banner>
        )}

        <Button variant="danger-soft" block className="signout" onClick={onSignOut}><Icon name="signOut" />تسجيل الخروج</Button>
      </main>
    </div>
  );
}
