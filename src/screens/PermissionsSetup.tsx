import { useCallback, useEffect, useState } from "react";
import type { SessionUser } from "../lib/api";
import { registerDevice, supportsPlatformAuthenticator, type BiometricState } from "../lib/biometric";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { geoGrantedBefore, readLocation } from "../lib/location";
import { BIO_HELP, bioReason, deviceInfo, diagLine, geoHelp, geoPermission, markSetupSeen, type BioEnv } from "../lib/permissions";
import { readPushState, subscribe, type PushState } from "../lib/push";
import type { LocationPolicy } from "../lib/types";
import { Banner, Icon, type IconName } from "./ui";

type Status = "done" | "todo" | "blocked" | "busy";

function Step({ icon, title, status, children }: { icon: IconName; title: string; status: Status; children?: React.ReactNode }) {
  const label = status === "done" ? "تم" : status === "blocked" ? "يحتاج إجراء" : status === "busy" ? "…" : "مطلوب";
  return (
    <li className={`perm-step ${status}`}>
      <div className="perm-head">
        <span className="perm-ico" aria-hidden="true"><Icon name={status === "done" ? "check" : icon} /></span>
        <span className="perm-title">{title}</span>
        <span className={`perm-chip ${status}`}>{label}</span>
      </div>
      {children && <div className="perm-body">{children}</div>}
    </li>
  );
}

function standalone(): boolean {
  return window.matchMedia?.("(display-mode: standalone)").matches || (navigator as { standalone?: boolean }).standalone === true;
}

async function bioEnv(): Promise<BioEnv> {
  const hasWebAuthn = typeof window.PublicKeyCredential === "function";
  let platformAuth: boolean | null = null;
  try {
    platformAuth = hasWebAuthn ? await window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable() : false;
  } catch {
    platformAuth = null;
  }
  return { ua: navigator.userAgent, secure: window.isSecureContext, hasWebAuthn, platformAuth, standalone: standalone() };
}

/**
 * After the new password and sign-in, before the app: location, fingerprint / Face ID, notifications — each asked with a
 * tap (browsers only show their permission prompt after a tap). The fingerprint registration stays REQUIRED when the
 * company asks for it and the phone can do it; location and notifications can be done later (a reminder stays on Home).
 */
export function PermissionsSetup({ user, locationPolicy, biometric, onDone }: {
  user: SessionUser;
  locationPolicy: LocationPolicy;
  biometric: BiometricState | undefined;
  onDone: () => void;
}) {
  const os = deviceInfo(navigator.userAgent).os;
  const needLocation = locationPolicy !== "none";
  const needBio = !!biometric && biometric.policy === "required";

  // ---- location
  const [geo, setGeo] = useState<Status>("todo");
  const [geoText, setGeoText] = useState<string | null>(null);
  useEffect(() => {
    if (needLocation && geoGrantedBefore()) { setGeo("done"); return; }
    if (needLocation) void geoPermission().then((s) => {
      if (s === "granted") setGeo("done");
      else if (s === "denied") { setGeo("blocked"); setGeoText(geoHelp("denied", os)); }
    });
  }, [needLocation, os]);
  async function askLocation() {
    setGeo("busy");
    setGeoText(null);
    const r = await readLocation("record");
    if (r.kind === "ok") { setGeo("done"); return; }
    setGeo("blocked");
    setGeoText(geoHelp(r.kind, os));
  }

  // ---- fingerprint / Face ID
  const [hasDevice, setHasDevice] = useState(!!biometric?.has_device);
  const [canBio, setCanBio] = useState<boolean | null>(null);
  const [env, setEnv] = useState<BioEnv | null>(null);
  const [bioBusy, setBioBusy] = useState(false);
  const [bioError, setBioError] = useState<string | null>(null);
  const checkBio = useCallback(async () => {
    setCanBio(null);
    const [can, e] = await Promise.all([supportsPlatformAuthenticator(), bioEnv()]);
    setEnv(e);
    setCanBio(can);
  }, []);
  useEffect(() => { if (needBio && !hasDevice) void checkBio(); }, [needBio, hasDevice, checkBio]);
  async function register() {
    setBioBusy(true);
    setBioError(null);
    try {
      await registerDevice(api);
      const state = await api.getAttendanceState();
      if (state.biometric?.has_device) setHasDevice(true);
      else setBioError("لم يكتمل تسجيل البصمة لهذا الجهاز. حاول مرة أخرى.");
    } catch (e) {
      const err = e instanceof AppError ? e : new AppError("unknown", String(e));
      setBioError(ERROR_TEXT[err.code]);
    } finally {
      setBioBusy(false);
    }
  }
  const bioStatus: Status = hasDevice ? "done" : bioBusy || canBio === null ? "busy" : canBio ? "todo" : "blocked";

  // ---- notifications
  const [push, setPush] = useState<PushState | null>(null);
  const [pushBusy, setPushBusy] = useState(false);
  const [pushText, setPushText] = useState<string | null>(null);
  useEffect(() => { void readPushState().then(setPush); }, []);
  async function askPush() {
    setPushBusy(true);
    setPushText(null);
    try {
      const keys = await subscribe();
      await api.savePushSubscription(keys);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "";
      setPushText(msg === "denied"
        ? "رفضت الإشعارات. فعّلها من إعدادات الهاتف ← التطبيقات ← المتصفح (أو وقتي) ← الإشعارات."
        : msg === "dismissed" ? "لم تُفعَّل. اضغط الزر مرة أخرى واختر «سماح»."
        : "تعذّر تفعيل الإشعارات على هذا الجهاز. حاول لاحقًا من تبويب الإشعارات.");
    } finally {
      setPushBusy(false);
      setPush(await readPushState());
    }
  }
  const pushStatus: Status = push === null || pushBusy ? "busy" : push === "on" ? "done" : push === "off" ? "todo" : "blocked";

  // The company rule stays: a phone that CAN register must register before the app opens.
  const mustRegister = needBio && !hasDevice && canBio !== false;
  const allDone = (!needLocation || geo === "done") && (!needBio || hasDevice) && pushStatus === "done";
  function finish() {
    markSetupSeen(user.id);
    onDone();
  }

  return (
    <main className="center-screen">
      <section className="card perm-card" aria-labelledby="perm-title">
        <h2 id="perm-title" className="pad-title">جهّز هاتفك للبصمة</h2>
        <p className="hint-line">اضغط كل زر، واختر «سماح» عندما يسألك الهاتف. هذا مرة واحدة فقط.</p>
        <ol className="perm-list">
          {needLocation && (
            <Step icon="pin" title="الموقع (GPS)" status={geo}>
              {geo !== "done" && <p className="hint-line">نحتاج موقعك عند تسجيل الحضور والانصراف فقط.</p>}
              {geoText && <Banner kind="warning">{geoText}</Banner>}
              {geo !== "done" && (
                <button className="btn primary block" onClick={askLocation} disabled={geo === "busy"} aria-busy={geo === "busy"}>
                  {geo === "busy" ? "جارٍ تحديد موقعك…" : "السماح بالموقع"}
                </button>
              )}
            </Step>
          )}
          {needBio && (
            <Step icon="fingerprint" title={os === "ios" ? "Face ID أو البصمة" : "البصمة"} status={bioStatus}>
              {!hasDevice && canBio && (
                <>
                  <p className="hint-line">يُسجَّل هاتف واحد لحسابك. شركتك تطلب هذه الخطوة.</p>
                  {bioError && <Banner kind="error" onClose={() => setBioError(null)}>{bioError}</Banner>}
                  <button className="btn primary block" onClick={register} disabled={bioBusy} aria-busy={bioBusy}>
                    {bioBusy ? "جارٍ التسجيل…" : os === "ios" ? "تسجيل Face ID" : "تسجيل البصمة"}
                  </button>
                </>
              )}
              {!hasDevice && canBio === false && env && (
                <>
                  <Banner kind="warning">{BIO_HELP[bioReason(env)]}</Banner>
                  <p className="perm-diag" dir="auto">{diagLine(env)}</p>
                  <button className="btn ghost block" onClick={() => void checkBio()}>أعد الفحص</button>
                  <p className="hint-line">إن لم ينجح: تستطيع المتابعة، وستُعلَّم بصماتك للمراجعة من الإدارة.</p>
                </>
              )}
            </Step>
          )}
          <Step icon="bell" title="الإشعارات (تذكير البصمة)" status={pushStatus}>
            {push === "off" && (
              <>
                <p className="hint-line">يصلك تذكير قبل بداية الدوام بـ 5 دقائق، وعند نهايته.</p>
                <button className="btn primary block" onClick={askPush} disabled={pushBusy} aria-busy={pushBusy}>
                  {pushBusy ? "جارٍ التفعيل…" : "تفعيل الإشعارات"}
                </button>
              </>
            )}
            {push === "ios_install" && (
              <Banner kind="warning">في الآيفون تعمل الإشعارات من التطبيق المثبّت فقط: اضغط زر المشاركة ثم «إضافة إلى الشاشة الرئيسية»، وافتح وقتي من أيقونته، ثم فعّل الإشعارات.</Banner>
            )}
            {push === "denied" && (
              <Banner kind="warning">الإشعارات ممنوعة لهذا التطبيق. فعّلها من إعدادات الهاتف ← التطبيقات ← المتصفح (أو وقتي) ← الإشعارات.</Banner>
            )}
            {push === "unsupported" && <p className="hint-line">هذا المتصفح لا يدعم الإشعارات. جرّب Chrome في الأندرويد.</p>}
            {pushText && <Banner kind="warning">{pushText}</Banner>}
          </Step>
        </ol>
        <button className="btn primary block" onClick={finish} disabled={mustRegister}>
          {allDone ? "ابدأ" : mustRegister ? "سجّل البصمة أولًا" : "متابعة"}
        </button>
        {!allDone && !mustRegister && <p className="hint-line">تستطيع إكمال الباقي لاحقًا من الرئيسية.</p>}
        <button className="btn quiet block" onClick={() => api.signOut()}>تسجيل الخروج</button>
      </section>
    </main>
  );
}
