import { useCallback, useEffect, useRef, useState } from "react";
import type { SessionUser } from "../lib/api";
import { api } from "../lib/client";
import { AppError } from "../lib/errors";
import { gateWhenUnreachable } from "../lib/firstRun";
import { browserStorage, loadCachedState } from "../lib/offlineQueue";
import { mustInstallFirst } from "../lib/deviceKey";
import { setupGate, setupSeen } from "../lib/permissions";
import type { AttendanceState } from "../lib/types";
import { Main } from "./Main";
import { PermissionsSetup } from "./PermissionsSetup";
import { Icon } from "./ui";

type Step =
  | { kind: "loading" } | { kind: "error" } | { kind: "ready" } | { kind: "setup"; state: AttendanceState }
  | { kind: "install" } | { kind: "locked" };

/**
 * Between the new password / sign-in and the app. The setup screen (location, fingerprint / Face ID, notifications)
 * comes first the first time on this phone, and always while the company requires the fingerprint and this phone is
 * not registered (nothing else is reachable then). If the state cannot be read the gate stays closed (retry).
 */
export function GateAfterPassword({ user }: { user: SessionUser }) {
  const [step, setStep] = useState<Step>({ kind: "loading" });

  const decide = useCallback(async (): Promise<Step> => {
    // iPhone in Safari: Safari and the installed app keep separate storage, so the phone is bound only inside the app.
    if (mustInstallFirst(navigator.userAgent, (navigator as { standalone?: boolean }).standalone)) return { kind: "install" };
    try {
      await api.bindDevice(); // this account opens only on its own phone (phase 16d)
      const state = await api.getAttendanceState();
      return setupGate(state.biometric, setupSeen(user.id)) === "home" ? { kind: "ready" } : { kind: "setup", state };
    } catch (e) {
      if (e instanceof AppError && e.code === "device_locked") return { kind: "locked" };
      if (e instanceof AppError && e.code === "not_authenticated") void api.signOut();
      // No connection: the state this phone saved last time decides (a returning employee can still start the app).
      if (e instanceof AppError && e.code === "network") {
        return { kind: gateWhenUnreachable(loadCachedState(browserStorage(), user.id)?.data.biometric) };
      }
      return { kind: "error" };
    }
  }, [user.id]);

  // Only the newest check may change the screen (a retry, or React running the effect twice, must not race).
  const latest = useRef(0);
  const start = useCallback(() => {
    const run = ++latest.current;
    setStep({ kind: "loading" });
    void decide().then((next) => { if (run === latest.current) setStep(next); });
  }, [decide]);
  useEffect(start, [start]);

  if (step.kind === "ready") return <Main user={user} />;
  if (step.kind === "loading") {
    return (
      <div className="center-screen" aria-busy="true">
        <div className="spinner" />
      </div>
    );
  }
  if (step.kind === "locked") {
    return (
      <main className="center-screen">
        <div className="card pad gate-locked">
          <Icon name="phone" className="pad-icon" />
          <h2 className="pad-title">لا يمكنك الدخول من هاتف آخر.</h2>
          <p className="muted">إذا غيّرت هاتفك، اطلب من الإدارة فك ربط الهاتف القديم، ثم سجّل الدخول من جديد.</p>
          <button className="btn ghost block" onClick={() => api.signOut()}>تسجيل الخروج</button>
        </div>
      </main>
    );
  }
  if (step.kind === "install") {
    return (
      <main className="center-screen">
        <div className="card pad gate-install">
          <Icon name="phone" className="pad-icon" />
          <h2 className="pad-title">ثبّت التطبيق أولًا</h2>
          <p className="muted">
            في الآيفون يعمل وقتي من أيقونته فقط: اضغط زر المشاركة في Safari ثم «إضافة إلى الشاشة الرئيسية»، وافتح وقتي من الأيقونة.
          </p>
          <button className="btn ghost block" onClick={() => api.signOut()}>تسجيل الخروج</button>
        </div>
      </main>
    );
  }
  if (step.kind === "error") {
    return (
      <main className="center-screen">
        <div className="card pad">
          <Icon name="alert" className="pad-icon" />
          <h2 className="pad-title">تعذّر التحقق من إعدادات حسابك</h2>
          <p className="muted">تحقق من اتصالك بالإنترنت ثم أعد المحاولة.</p>
          <div className="row">
            <button className="btn primary" onClick={start}>إعادة المحاولة</button>
            <button className="btn ghost" onClick={() => api.signOut()}>تسجيل الخروج</button>
          </div>
        </div>
      </main>
    );
  }
  return (
    <PermissionsSetup
      user={user}
      locationPolicy={step.state.location_policy}
      biometric={step.state.biometric}
      onDone={() => setStep({ kind: "ready" })}
    />
  );
}
