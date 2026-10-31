import { useEffect, useRef, useState } from "react";
import { newRequestId } from "../lib/attendance";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT, type AppErrorCode } from "../lib/errors";
import {
  actualLine,
  emptyOvertimeDraft,
  limitsLine,
  overtimeDay,
  overtimeHours,
  overtimeInput,
  overtimeSignature,
  PHASE_LABEL,
  shiftLine,
  sortOvertime,
  type OvertimeDraft,
} from "../lib/overtime";
import { addDays, formatDay, formatMinutes } from "../lib/requests";
import type { OvertimeItem, OvertimeOverview, OvertimePreview } from "../lib/types";

type Done = (text: string, kind: "success" | "error") => void;

const errText = (e: unknown) => {
  const code: AppErrorCode = e instanceof AppError ? e.code : "unknown";
  return code === "network" ? "لم يصل رد من الخادم. حاول مرة أخرى." : ERROR_TEXT[code];
};

// ---------------------------------------------------------------- assigned to me

export function MyOvertime({ data, online, onDone }: { data: OvertimeOverview; online: boolean; onDone: Done }) {
  const items = sortOvertime(data.mine).filter((o) => o.phase !== "cancelled" || Date.parse(o.start_at) > Date.now() - 7 * 86_400_000);
  if (items.length === 0) return null;
  return (
    <section aria-labelledby="ot-mine-title">
      <h2 id="ot-mine-title" className="section-title">العمل الإضافي المكلَّف به</h2>
      <ul className="req-list">
        {items.map((o) => <li key={o.id}><MyOvertimeCard item={o} tz={data.timezone} online={online} onDone={onDone} /></li>)}
      </ul>
    </section>
  );
}

function MyOvertimeCard({ item, tz, online, onDone }: { item: OvertimeItem; tz: string; online: boolean; onDone: Done }) {
  const [writing, setWriting] = useState(false);
  const [note, setNote] = useState(item.employee_note ?? "");
  const [busy, setBusy] = useState(false);
  const open = item.phase === "upcoming" || item.phase === "now";
  const actual = actualLine(item);

  async function send() {
    if (busy || !note.trim()) return;
    setBusy(true);
    try {
      await api.noteOvertime(item.id, note.trim());
      setWriting(false);
      onDone(`أُرسلت ملاحظتك إلى ${item.assigned_by.full_name}.`, "success");
    } catch (e) {
      onDone(errText(e), "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className={`req-card ot-card ${item.phase}`}>
      <header className="req-card-head">
        <p className="req-title">عمل إضافي · {formatMinutes(item.minutes)}</p>
        <span className={`chip ot-${item.phase}`}>{PHASE_LABEL[item.phase]}</span>
      </header>
      <p className="req-period">{formatDay(overtimeDay(item, tz))}{" · "}<span dir="ltr">{overtimeHours(item, tz)}</span></p>
      {item.task && <p className="req-reason">«{item.task}»</p>}
      <p className="req-progress">كلّفك: {item.assigned_by.full_name}{item.phase === "cancelled" && item.cancelled_by_name ? ` · ألغاه: ${item.cancelled_by_name}` : ""}</p>
      {actual && <p className="req-meta">{actual}</p>}
      {item.employee_note && !writing && <p className="ot-note">ملاحظتك: «{item.employee_note}»</p>}
      {open && (writing ? (
        <div className="reject-box">
          <label className="field">
            <span>ملاحظة لمن كلّفك (مثلًا: لا أستطيع الحضور ولماذا)</span>
            <textarea value={note} maxLength={500} rows={2} onChange={(e) => setNote(e.target.value)} />
          </label>
          <div className="row end">
            <button className="btn ghost" onClick={() => setWriting(false)} disabled={busy}>تراجع</button>
            <button className="btn primary" onClick={send} disabled={busy || !online || !note.trim()} aria-busy={busy}>إرسال الملاحظة</button>
          </div>
        </div>
      ) : (
        <button className="btn ghost small cancel" onClick={() => setWriting(true)} disabled={!online}>
          {item.employee_note ? "تعديل الملاحظة" : "لا أستطيع / ملاحظة"}
        </button>
      ))}
    </article>
  );
}

// ---------------------------------------------------------------- what I assigned (managers)

export function TeamOvertime({ data, online, onDone, onAssign }: { data: OvertimeOverview; online: boolean; onDone: Done; onAssign: () => void }) {
  if (data.team.length === 0) return null;
  const items = sortOvertime(data.assigned_by_me);
  return (
    <section aria-labelledby="ot-team-title">
      <div className="section-head">
        <h2 id="ot-team-title" className="section-title">العمل الإضافي لفريقك</h2>
        <button className="btn small" onClick={onAssign} disabled={!online}>تكليف بعمل إضافي</button>
      </div>
      {items.length === 0 ? (
        <p className="muted empty">لم تكلّف أحدًا بعد.</p>
      ) : (
        <ul className="req-list">
          {items.map((o) => <li key={o.id}><TeamOvertimeCard item={o} tz={data.timezone} online={online} onDone={onDone} /></li>)}
        </ul>
      )}
    </section>
  );
}

function TeamOvertimeCard({ item, tz, online, onDone }: { item: OvertimeItem; tz: string; online: boolean; onDone: Done }) {
  const [busy, setBusy] = useState(false);
  const actual = actualLine(item);
  async function cancel() {
    if (busy || !window.confirm(`إلغاء تكليف ${item.employee.full_name}؟ سيصله إشعار بالإلغاء.`)) return;
    setBusy(true);
    try {
      await api.cancelOvertime(item.id);
      onDone("أُلغي التكليف.", "success");
    } catch (e) {
      onDone(errText(e), "error");
    } finally {
      setBusy(false);
    }
  }
  return (
    <article className={`req-card ot-card ${item.phase}${item.employee_note && item.phase !== "cancelled" ? " has-note" : ""}`}>
      <header className="req-card-head">
        <div className="min-w-0">
          <p className="req-who truncate">{item.employee.full_name}</p>
          <p className="req-title">عمل إضافي · {formatMinutes(item.minutes)}</p>
        </div>
        <span className={`chip ot-${item.phase}`}>{PHASE_LABEL[item.phase]}</span>
      </header>
      <p className="req-period">{formatDay(overtimeDay(item, tz))}{" · "}<span dir="ltr">{overtimeHours(item, tz)}</span></p>
      {item.task && <p className="req-reason">«{item.task}»</p>}
      {item.employee_note && <p className="ot-note">ملاحظة الموظف: «{item.employee_note}»</p>}
      {actual && <p className="req-meta">{actual}</p>}
      {item.phase === "upcoming" && (
        <button className="btn ghost small cancel" onClick={cancel} disabled={busy || !online}>إلغاء التكليف</button>
      )}
    </article>
  );
}

// ---------------------------------------------------------------- the assignment form

const PREVIEW_DELAY_MS = 400;

export function AssignOvertimeForm({ data, online, onClose, onSent }: {
  data: OvertimeOverview; online: boolean; onClose: () => void; onSent: (o: OvertimeItem) => void;
}) {
  const tz = data.timezone;
  const [draft, setDraft] = useState<OvertimeDraft>(() => emptyOvertimeDraft(data.today, data.team.length === 1 ? data.team[0].id : ""));
  const [preview, setPreview] = useState<{ sig: string; result: OvertimePreview } | null>(null);
  const [previewError, setPreviewError] = useState<{ sig: string; text: string } | null>(null);
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const key = useRef<{ sig: string; key: string } | null>(null);

  const built = overtimeInput(draft, tz);
  const sig = built.ok ? overtimeSignature(built.input) : null;

  useEffect(() => {
    if (!built.ok || !online) return;
    const input = built.input;
    const s = overtimeSignature(input);
    let alive = true;
    const t = setTimeout(async () => {
      try {
        const result = await api.previewOvertime(input);
        if (alive) { setPreview({ sig: s, result }); setPreviewError(null); }
      } catch (e) {
        if (alive) setPreviewError({ sig: s, text: errText(e) });
      }
    }, PREVIEW_DELAY_MS);
    return () => { alive = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the signature is the content
  }, [sig, online]);

  const set = (patch: Partial<OvertimeDraft>) => { setSendError(null); setDraft((d) => ({ ...d, ...patch })); };
  const current = preview && preview.sig === sig ? preview.result : null;
  const problem = !built.ok ? (built.error ? ERROR_TEXT[built.error] : null) : previewError && previewError.sig === sig ? previewError.text : null;
  const canSend = built.ok && current !== null && problem === null && !sending && online;

  async function send() {
    if (!built.ok || !canSend) return;
    if (!key.current || key.current.sig !== sig) key.current = { sig: sig!, key: newRequestId() };
    setSending(true);
    setSendError(null);
    try {
      onSent(await api.assignOvertime(key.current.key, built.input));
    } catch (e) {
      setSendError(e instanceof AppError && e.code === "network"
        ? "لم يصل رد من الخادم. اضغط «تكليف» مرة أخرى — لن يُكرَّر التكليف."
        : errText(e));
    } finally {
      setSending(false);
    }
  }

  const direct = data.team.filter((t) => t.direct);
  const below = data.team.filter((t) => !t.direct);
  const limits = data.limits;

  return (
    <main className="container requests">
      <div className="req-head">
        <h1 className="screen-title">تكليف بعمل إضافي</h1>
        <button className="btn ghost small" onClick={onClose} disabled={sending}>رجوع</button>
      </div>

      <div className="form card">
        <label className="field">
          <span>الموظف</span>
          <select value={draft.employee_id} onChange={(e) => set({ employee_id: e.target.value })}>
            <option value="">اختر الموظف…</option>
            {direct.length > 0 && (
              <optgroup label="يتبعونك مباشرة">
                {direct.map((t) => <option key={t.id} value={t.id}>{t.full_name}</option>)}
              </optgroup>
            )}
            {below.length > 0 && (
              <optgroup label="ضمن فريقك">
                {below.map((t) => <option key={t.id} value={t.id}>{t.full_name}{t.department ? ` — ${t.department}` : ""}</option>)}
              </optgroup>
            )}
          </select>
        </label>
        <label className="field">
          <span>اليوم</span>
          <input type="date" value={draft.date} min={data.today} max={addDays(data.today, 60)} onChange={(e) => set({ date: e.target.value })} />
        </label>
        <div className="two">
          <label className="field">
            <span>من الساعة</span>
            <input type="time" value={draft.from} step={300} onChange={(e) => set({ from: e.target.value })} />
          </label>
          <label className="field">
            <span>إلى الساعة</span>
            <input type="time" value={draft.to} step={300} onChange={(e) => set({ to: e.target.value })} />
          </label>
        </div>
        <p className="muted small">
          خارج دوامه فقط: قبله أو بعده أو في يوم عطلته.
          {(limits.day_minutes !== null || limits.month_minutes !== null) && " الحد الأقصى: "}
          {limits.day_minutes !== null && `${formatMinutes(limits.day_minutes)} في اليوم`}
          {limits.day_minutes !== null && limits.month_minutes !== null && " و"}
          {limits.month_minutes !== null && `${formatMinutes(limits.month_minutes)} في الشهر`}
          {(limits.day_minutes !== null || limits.month_minutes !== null) && "."}
        </p>
        <label className="field">
          <span>المهمة (اختياري، يراها الموظف)</span>
          <textarea value={draft.task} maxLength={500} rows={2} onChange={(e) => set({ task: e.target.value })} placeholder="مثال: جرد المخزن الرئيسي" />
        </label>
      </div>

      {problem ? (
        <p className="preview bad" role="alert">{problem}</p>
      ) : built.ok && online && !current ? (
        <p className="preview muted" aria-live="polite">جارٍ التحقق…</p>
      ) : current ? (
        <div className="preview ok" aria-live="polite">
          <p><strong>{formatMinutes(current.minutes)}</strong> · {shiftLine(current, tz)}</p>
          <p className="small">{limitsLine(current)}</p>
        </div>
      ) : null}

      {sendError && <div className="banner error" role="alert"><span>{sendError}</span></div>}
      {!online && <div className="banner warning" role="alert">لا يوجد اتصال بالإنترنت.</div>}

      <button className="btn primary block send" onClick={send} disabled={!canSend} aria-busy={sending}>
        {sending ? "جارٍ الإرسال…" : "تكليف"}
      </button>
    </main>
  );
}
