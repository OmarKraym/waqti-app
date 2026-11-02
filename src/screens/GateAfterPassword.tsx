import { useCallback, useEffect, useRef, useState } from "react";
import type { SessionUser } from "../lib/api";
import { supportsPlatformAuthenticator } from "../lib/biometric";
import { api } from "../lib/client";
import { AppError } from "../lib/errors";
import { nextGate } from "../lib/firstRun";
import { DeviceSetup } from "./DeviceSetup";
import { Main } from "./Main";
import { Banner, Icon } from "./ui";

type Step = "loading" | "error" | "device" | "unsupported" | "ready";

/**
 * Between the new password and the app: when the company requires the fingerprint and this phone is not registered,
 * the registration comes FIRST (nothing else is reachable). If the state cannot be read the gate stays closed (retry).
 */
export function GateAfterPassword({ user }: { user: SessionUser }) {
  const [step, setStep] = useState<Step>("loading");
  const [note, setNote] = useState<string | null>(null);

  const decide = useCallback(async (): Promise<Step> => {
    try {
      const state = await api.getAttendanceState();
      const b = state.biometric;
      const needs = !!b && b.policy === "required" && !b.has_device;
      const gate = nextGate(b, needs ? await supportsPlatformAuthenticator() : true);
      return gate === "home" ? "ready" : gate;
    } catch (e) {
      if (e instanceof AppError && e.code === "not_authenticated") void api.signOut();
      return "error";
    }
  }, []);

  // Only the newest check may change the screen (a retry, or React running the effect twice, must not race).
  const latest = useRef(0);
  const start = useCallback(() => {
    const run = ++latest.current;
    setStep("loading");
    void decide().then((next) => { if (run === latest.current) setStep(next); });
  }, [decide]);
  useEffect(start, [start]);

  async function registered() {
    const run = ++latest.current;
    const next = await decide();
    if (run !== latest.current) return;
    if (next === "device") setNote("لم يكتمل تسجيل البصمة لهذا الجهاز. حاول مرة أخرى.");
    else setNote(null);
    setStep(next);
  }

  if (step === "ready") return <Main user={user} />;
  if (step === "loading") {
    return (
      <div className="center-screen" aria-busy="true">
        <div className="spinner" />
      </div>
    );
  }
  if (step === "error") {
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
  if (step === "unsupported") {
    return (
      <main className="center-screen">
        <div className="card pad gate-unsupported">
          <Icon name="phone" className="pad-icon" />
          <h2 className="pad-title">هذا الجهاز لا يدعم البصمة</h2>
          <p className="muted">
            شركتك تطلب البصمة، لكن هذا الهاتف لا يدعمها. تستطيع المتابعة، وستُعلَّم بصماتك للمراجعة من الإدارة.
          </p>
          <button className="btn primary block" onClick={() => setStep("ready")}>متابعة</button>
        </div>
      </main>
    );
  }
  return (
    <main className="center-screen">
      <div className="gate-stack">
        {note && <Banner kind="error" onClose={() => setNote(null)}>{note}</Banner>}
        <DeviceSetup onDone={registered} onSignOut={() => api.signOut()} />
      </div>
    </main>
  );
}
