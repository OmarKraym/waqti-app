import { useEffect, useRef, useState } from "react";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT } from "../lib/errors";
import { keysOf, currentSubscription, readPushState, subscribe, unsubscribe, type PushState } from "../lib/push";
import type { NotificationSettings } from "../lib/types";
import { AppBar, Banner, Icon } from "./ui";

type Note = { kind: "success" | "warning" | "error"; text: string } | null;

const BEFORE_IN = [0, 5, 10, 15, 30, 60];
const BEFORE_OUT = [0, 5, 10, 15, 30];

const minutesLabel = (m: number, at: string) => (m === 0 ? at : m === 60 ? "قبلها بساعة" : `قبلها بـ ${m} دقيقة`);

export function Notifications({ online }: { online: boolean }) {
  const [push, setPush] = useState<PushState | null>(null);
  const [settings, setSettings] = useState<NotificationSettings | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note>(null);
  const saveRun = useRef(0);

  async function refresh() {
    setPush(await readPushState());
    try {
      setSettings(await api.getNotificationSettings());
      setLoadError(false);
    } catch (e) {
      if (e instanceof AppError && e.code === "not_authenticated") return void api.signOut();
      setLoadError(true);
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  const fail = (e: unknown) => {
    const code = e instanceof AppError ? e.code : "unknown";
    setNote({ kind: "error", text: code === "network" ? "لا يوجد اتصال بالخادم. حاول مرة أخرى." : ERROR_TEXT[code] });
  };

  async function turnOn() {
    if (busy) return;
    setBusy(true);
    setNote(null);
    try {
      const keys = await subscribe();
      await api.savePushSubscription(keys);
      setNote({ kind: "success", text: "تم تفعيل الإشعارات على هذا الجهاز." });
    } catch (e) {
      const msg = e instanceof Error ? e.message : "";
      if (msg === "denied") setNote({ kind: "error", text: "رفضت الإذن بالإشعارات. يمكنك السماح بها لاحقًا من إعدادات المتصفح أو الهاتف." });
      else if (msg === "dismissed") setNote({ kind: "warning", text: "لم تُفعَّل الإشعارات. اضغط «تفعيل الإشعارات» ثم اختر «سماح»." });
      else if (e instanceof AppError) fail(e);
      else setNote({ kind: "error", text: "تعذّر تفعيل الإشعارات على هذا الجهاز." });
    } finally {
      setBusy(false);
      refresh();
    }
  }

  async function turnOff() {
    if (busy) return;
    setBusy(true);
    setNote(null);
    try {
      const endpoint = await unsubscribe();
      if (endpoint) await api.deletePushSubscription(endpoint);
      setNote({ kind: "success", text: "أُوقفت الإشعارات على هذا الجهاز." });
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
      refresh();
    }
  }

  async function test() {
    if (busy) return;
    setBusy(true);
    setNote(null);
    try {
      // Make sure the server knows this device (e.g. after signing in again on it).
      const sub = await currentSubscription();
      if (sub) await api.savePushSubscription(keysOf(sub));
      await api.testNotification();
      setNote({ kind: "success", text: "أُرسل إشعار تجريبي. يصل خلال ثوانٍ." });
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  }

  async function save(next: NotificationSettings) {
    const prev = settings;
    setSettings(next); // shown at once; reverted if the server refuses
    const mine = ++saveRun.current;
    try {
      const saved = await api.setNotificationSettings(next);
      if (mine === saveRun.current) setSettings(saved);
    } catch (e) {
      if (mine === saveRun.current) setSettings(prev);
      fail(e);
    }
  }

  return (
    <>
    <AppBar title="الإشعارات" />
    <main className="container notif">
      {!online && <Banner kind="warning">الإعدادات تحتاج اتصالًا بالإنترنت.</Banner>}
      {note && <Banner kind={note.kind} onClose={() => setNote(null)}>{note.text}</Banner>}

      <section className="notif-card" aria-labelledby="device-title">
        <h2 id="device-title" className="section-title">هذا الجهاز</h2>
        {push === null ? (
          <p className="muted">جارٍ التحقق…</p>
        ) : push === "on" ? (
          <>
            <p className="state-line on"><Icon name="check" />الإشعارات مفعّلة على هذا الجهاز.</p>
            <div className="actions">
              <button className="btn" onClick={test} disabled={busy || !online}>إرسال إشعار تجريبي</button>
              <button className="btn danger-text" onClick={turnOff} disabled={busy || !online}>إيقاف على هذا الجهاز</button>
            </div>
          </>
        ) : push === "off" ? (
          <>
            <p className="state-line"><Icon name="bell" />فعّلها لتصلك الطلبات وتذكيرات الدوام حتى والتطبيق مغلق.</p>
            <button className="btn primary block" onClick={turnOn} disabled={busy || !online} aria-busy={busy}>
              {busy ? "جارٍ التفعيل…" : "تفعيل الإشعارات"}
            </button>
          </>
        ) : push === "ios_install" ? (
          <p>على iPhone تصل الإشعارات فقط من التطبيق المثبّت: اضغط زر المشاركة في Safari ثم «إضافة إلى الشاشة الرئيسية»، وافتح التطبيق من أيقونته ثم ارجع إلى هنا.</p>
        ) : push === "denied" ? (
          <p className="state-line alert-text"><Icon name="alert" />الإشعارات محظورة لهذا التطبيق. اسمح بها من إعدادات المتصفح أو الهاتف، ثم ارجع إلى هنا.</p>
        ) : (
          <p>هذا المتصفح لا يدعم الإشعارات. جرّب متصفح Chrome، أو ثبّت التطبيق على الشاشة الرئيسية.</p>
        )}
      </section>

      <section className="notif-card" aria-labelledby="req-n-title">
        <h2 id="req-n-title" className="section-title">الطلبات</h2>
        <p className="card-text">تصلك تلقائيًا: كل طلب ينتظر موافقتك عندما يصل دورك في مسار الموافقات، ونتيجة طلباتك (موافقة أو رفض).</p>
      </section>

      <section className="notif-card" aria-labelledby="rem-title">
        <h2 id="rem-title" className="section-title">تذكير الحضور والانصراف</h2>
        {!settings ? (
          loadError ? (
            <div className="state-row"><span className="muted">تعذّر تحميل الإعدادات.</span><button className="btn small" onClick={refresh}>إعادة المحاولة</button></div>
          ) : (
            <p className="muted">جارٍ التحميل…</p>
          )
        ) : (
          <>
            <div className="rem-row">
              <label className="switch">
                <span>تذكير بتسجيل الحضور</span>
                <input type="checkbox" checked={settings.remind_check_in} disabled={!online}
                       onChange={(e) => save({ ...settings, remind_check_in: e.target.checked })} />
              </label>
              <select aria-label="وقت تذكير الحضور" value={settings.check_in_before} disabled={!online || !settings.remind_check_in}
                      onChange={(e) => save({ ...settings, check_in_before: Number(e.target.value) })}>
                {BEFORE_IN.map((m) => <option key={m} value={m}>{minutesLabel(m, "عند بداية الدوام")}</option>)}
              </select>
            </div>
            <div className="rem-row">
              <label className="switch">
                <span>تذكير بتسجيل الانصراف</span>
                <input type="checkbox" checked={settings.remind_check_out} disabled={!online}
                       onChange={(e) => save({ ...settings, remind_check_out: e.target.checked })} />
              </label>
              <select aria-label="وقت تذكير الانصراف" value={settings.check_out_before} disabled={!online || !settings.remind_check_out}
                      onChange={(e) => save({ ...settings, check_out_before: Number(e.target.value) })}>
                {BEFORE_OUT.map((m) => <option key={m} value={m}>{minutesLabel(m, "عند نهاية الدوام")}</option>)}
              </select>
            </div>
            <p className="hint-line">
              حسب جدول دوامك. لا يصلك تذكير الحضور إذا سجّلت حضورك أو كنت في إجازة، ولا تذكير الانصراف إذا لم تكن مسجّلًا حضورك.
            </p>
            {(settings.remind_check_in || settings.remind_check_out) && settings.devices === 0 && (
              <p className="hint-line alert-text">لن تصلك التذكيرات حتى تفعّل الإشعارات على جهاز واحد على الأقل.</p>
            )}
          </>
        )}
      </section>
    </main>
    </>
  );
}
