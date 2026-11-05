import { useEffect, useMemo, useRef, useState } from "react";
import { newRequestId } from "../lib/attendance";
import { api } from "../lib/client";
import { AppError, ERROR_TEXT, type AppErrorCode } from "../lib/errors";
import {
  LEAVE_LABEL,
  STATUS_LABEL,
  addDays,
  draftToRequest,
  clampLeaveDates,
  emptyDraft,
  leaveEarliest,
  formatDays,
  formatMinutes,
  formatDay,
  formatPeriod,
  formatTimes,
  permissionLeft,
  permissionTimesFilled,
  progressLine,
  visibleNote,
  remainingAfter,
  requestSignature,
  requestTitle,
  visibleSteps,
  KIND_LABEL,
  type Draft,
} from "../lib/requests";
import type { InboxItem, LeaveType, PermissionUsage, RequestItem, RequestPreview, RequestType, RequestsOverview } from "../lib/types";
import { AssignOvertimeForm, MyOvertime, TeamOvertime } from "./Overtime";
import type { RequestsData } from "./useRequests";
import { TimeField } from "./TimeField";
import { AppBar, Banner, Icon } from "./ui";

type Note = { kind: "success" | "warning" | "error"; text: string };
const TYPE_ICON = { leave: "calendar", permission: "clock", other: "doc" } as const;

export function Requests({ data, online, compose }: {
  data: RequestsData;
  online: boolean;
  /** Set by the today screen's shortcuts: open the form with this type (n changes on every tap). */
  compose?: { n: number; type: RequestType; draft?: Draft } | null;
}) {
  const { overview, inbox, overtime, loading, error, savedAt, reload } = data;
  const [composing, setComposing] = useState<{ type: RequestType; draft?: Draft } | null>(compose ? { type: compose.type, draft: compose.draft } : null);
  const [assigning, setAssigning] = useState(false);
  const [note, setNote] = useState<Note | null>(null);
  const done = (text: string, kind: "success" | "error") => { setNote({ kind, text }); reload(); };
  useEffect(() => {
    if (!compose) return;
    setNote(null);
    setAssigning(false);
    setComposing({ type: compose.type, draft: compose.draft });
  }, [compose?.n]); // eslint-disable-line react-hooks/exhaustive-deps

  if (assigning && overtime) {
    return (
      <AssignOvertimeForm
        data={overtime}
        online={online}
        onClose={() => setAssigning(false)}
        onSent={(o) => {
          setAssigning(false);
          done(`كُلِّف ${o.employee.full_name}، ووصله إشعار.`, "success");
        }}
      />
    );
  }

  if (composing && overview) {
    return (
      <NewRequestForm
        initialType={composing.type}
        initialDraft={composing.draft}
        overview={overview}
        online={online}
        onClose={() => setComposing(null)}
        onSent={(r) => {
          setComposing(null);
          setNote({ kind: "success", text: sentText(r) });
          reload();
        }}
      />
    );
  }

  return (
    <>
    <AppBar className="req-head" title="الطلبات" />
    <main className="container requests has-fab">
      {!online && <Banner kind="warning">الطلبات تحتاج اتصالًا بالإنترنت.</Banner>}
      {note && <Banner kind={note.kind} onClose={() => setNote(null)}>{note.text}</Banner>}

      {!overview ? (
        loading ? (
          <div className="center-block" aria-busy="true"><div className="spinner" /></div>
        ) : (
          <div className="card pad">
            <Icon name="alert" className="pad-icon" />
            <p className="muted">{error?.code === "network" ? "تحقق من اتصالك بالإنترنت." : ERROR_TEXT[error?.code ?? "unknown"]}</p>
            <button className="btn primary" onClick={reload}>إعادة المحاولة</button>
          </div>
        )
      ) : (
        <>
          {savedAt !== null && (
            <p className="summary-stale">آخر تحديث {new Date(savedAt).toLocaleDateString("en-GB")} {new Date(savedAt).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })} — {online ? "تعذّر التحديث الآن." : "لا يوجد اتصال."}</p>
          )}
          <Balances overview={overview} />
          {inbox.length > 0 && (
            <Inbox items={inbox} timeZone={overview.timezone} online={online} onDone={(text, kind) => { setNote({ kind, text }); reload(); }} />
          )}
          {overtime && <MyOvertime data={overtime} online={online} onDone={done} />}
          <PermissionUsage overview={overview} />
          <MyRequests
            items={overview.requests}
            timeZone={overview.timezone}
            online={online}
            onChanged={(text, kind) => { setNote({ kind, text }); reload(); }}
          />
          {overtime && <TeamOvertime data={overtime} online={online} onDone={done} onAssign={() => { setNote(null); setAssigning(true); }} />}
        </>
      )}
    </main>
    {/* The main action of this tab floats where the punch button floats on the today tab. */}
    <button className="fab new-req" onClick={() => { setNote(null); setComposing({ type: "leave" }); }} disabled={!overview || !online}>
      <span className="fab-icon" aria-hidden="true"><Icon name="plus" /></span>
      <span className="fab-label">طلب جديد</span>
    </button>
    </>
  );
}

function sentText(r: RequestItem): string {
  const at = visibleSteps(r.steps).find((s) => s.status === "pending");
  const who = at ? (at.kind === "hr" ? KIND_LABEL.hr : at.approver_name ?? KIND_LABEL[at.kind]) : null;
  return who ? `أُرسل الطلب، وهو الآن بانتظار: ${who}.` : "أُرسل الطلب.";
}

// ---------------------------------------------------------------- waiting for my decision

function Inbox({ items, timeZone, online, onDone }: {
  items: InboxItem[]; timeZone: string; online: boolean; onDone: (text: string, kind: "success" | "error") => void;
}) {
  return (
    <section className="inbox" aria-labelledby="inbox-title">
      <h2 id="inbox-title" className="section-title">بانتظار موافقتك <span className="count">{items.length}</span></h2>
      <ul className="req-list">
        {items.map((it) => (
          <li key={it.approval_id}><InboxCard item={it} timeZone={timeZone} online={online} onDone={onDone} /></li>
        ))}
      </ul>
    </section>
  );
}

function InboxCard({ item, timeZone, online, onDone }: {
  item: InboxItem; timeZone: string; online: boolean; onDone: (text: string, kind: "success" | "error") => void;
}) {
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<AppErrorCode | null>(null);
  const period = formatPeriod(item, timeZone);
  const after = remainingAfter(item.balance, item.days);

  async function decide(decision: "approve" | "reject") {
    if (busy) return;
    setBusy(true);
    setErr(null);
    try {
      const r = await api.decide(item.approval_id, decision, decision === "reject" ? reason.trim() || null : null);
      const name = item.employee.full_name;
      onDone(
        decision === "reject"
          ? `رُفض طلب ${name}.`
          : r.status === "approved" ? `وافقت على طلب ${name}، واكتملت موافقاته.` : `وافقت على طلب ${name}، وانتقل للخطوة التالية.`,
        "success",
      );
    } catch (e) {
      const code = e instanceof AppError ? e.code : "unknown";
      // Decided elsewhere meanwhile: refresh the list instead of showing a dead card.
      if (code === "already_decided" || code === "request_not_found") return onDone(ERROR_TEXT[code], "error");
      setErr(code);
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className="req-card approve-card">
      <header className="req-card-head">
        <span className="avatar-sm" aria-hidden="true">{item.employee.full_name.trim().charAt(0)}</span>
        <div className="req-head-text">
          <p className="req-who truncate">{item.employee.full_name}</p>
          <p className="req-title">{requestTitle(item)}{item.days !== null && ` · ${formatDays(item.days)}`}{item.minutes !== null && ` · ${formatMinutes(item.minutes)}`}</p>
        </div>
        <span className="step-of">الخطوة {visibleSteps(item.steps).findIndex((s) => s.step_order === item.my_step) + 1} من {item.step_count}</span>
      </header>
      <p className="req-period"><Icon name={TYPE_ICON[item.type]} className="inline-icon" />{period.day}{period.time && <>{" · "}<span>{period.time}</span></>}</p>
      {item.reason && <p className="req-reason">«{item.reason}»</p>}
      {item.balance && item.balance.entitled !== null && (
        <p className="req-meta">رصيده المتبقي بعد الموافقة: <strong>{formatDays(Math.max(after ?? 0, 0))}</strong> من {formatDays(item.balance.entitled)}</p>
      )}
      {item.permission && (
        <p className="req-meta">
          {item.permission.max_per_month === null
            ? `هذا النوع بلا حد لعدد المرات (طلب ${formatTimes(item.permission.used + item.permission.pending + 1)} هذا الشهر).`
            : <>استخدم هذا الشهر <strong>{item.permission.used + item.permission.pending}</strong> من {item.permission.max_per_month} قبل هذا الطلب.</>}
        </p>
      )}
      {err && <p className="form-error" role="alert">{err === "network" ? "لم يصل رد. حاول مرة أخرى؛ لن يُسجّل القرار مرتين." : ERROR_TEXT[err]}</p>}
      {rejecting ? (
        <div className="reject-box">
          <label className="field">
            <span>سبب الرفض (يراه الموظف، اختياري)</span>
            <textarea value={reason} maxLength={500} rows={2} onChange={(e) => setReason(e.target.value)} />
          </label>
          <div className="actions">
            <button className="btn" onClick={() => setRejecting(false)} disabled={busy}>تراجع</button>
            <button className="btn danger" onClick={() => decide("reject")} disabled={busy || !online} aria-busy={busy}>تأكيد الرفض</button>
          </div>
        </div>
      ) : (
        <div className="actions">
          <button className="btn danger-text" onClick={() => setRejecting(true)} disabled={busy || !online}>رفض</button>
          <button className="btn primary" onClick={() => decide("approve")} disabled={busy || !online} aria-busy={busy}>
            {busy ? "جارٍ الإرسال…" : "موافقة"}
          </button>
        </div>
      )}
    </article>
  );
}

// ---------------------------------------------------------------- balances

function Balances({ overview }: { overview: RequestsOverview }) {
  const annual = overview.balances.find((b) => b.leave_type === "annual");
  const others = overview.balances.filter((b) => b.leave_type !== "annual" && (b.used > 0 || b.pending > 0));
  if (!(annual && annual.remaining !== null) && others.length === 0) return null;
  const entitled = annual?.entitled ?? 0;
  const pct = (n: number) => (entitled > 0 ? Math.min(100, Math.max(0, (n / entitled) * 100)) : 0);
  return (
    <section className="balances" aria-label="أرصدتي">
      {annual && annual.remaining !== null && (
        <div className="balance annual">
          <span className="balance-label">الإجازة السنوية</span>
          <span className="balance-value">{formatDays(annual.remaining)}</span>
          <span className="balance-sub">متبقٍ من {formatDays(entitled)}{annual.pending > 0 && ` · ${formatDays(annual.pending)} قيد الموافقة`}</span>
          {entitled > 0 && (
            <div className="balance-bar" role="img" aria-label={`مستخدم ${formatDays(annual.used)} وقيد الموافقة ${formatDays(annual.pending)} من ${formatDays(entitled)}`}>
              <span className="used" style={{ width: `${pct(annual.used)}%` }} />
              <span className="pend" style={{ width: `${pct(annual.pending)}%` }} />
            </div>
          )}
          <dl className="balance-stats">
            <div><dt>مستخدمة</dt><dd>{formatDays(annual.used)}</dd></div>
            <div><dt>قيد الموافقة</dt><dd>{formatDays(annual.pending)}</dd></div>
            <div><dt>الرصيد الكلي</dt><dd>{formatDays(entitled)}</dd></div>
          </dl>
        </div>
      )}
      {others.length > 0 && (
        <p className="balance-others">
          {others.map((b) => `${LEAVE_LABEL[b.leave_type]}: ${formatDays(b.used + b.pending)} هذه السنة`).join(" · ")}
        </p>
      )}
    </section>
  );
}

function PermissionUsage({ overview }: { overview: RequestsOverview }) {
  if (overview.permission_types.length === 0) return null;
  return (
    <section className="perms" aria-labelledby="perm-title">
      <h2 id="perm-title" className="section-title">الأذونات هذا الشهر</h2>
      <div className="balance">
        <ul className="perm-usage">
          {overview.permission_types.map((p) => {
            const left = permissionLeft(p);
            const share = left === null || !p.max_per_month ? 1 : left / p.max_per_month;
            return (
              <li key={p.id}>
                <span className="perm-name">{p.name}</span>
                <span className={`perm-left${left === 0 ? " none" : share < 0.5 ? " low" : ""}`}>
                  {left === null ? "بلا حد" : left === 0 ? "استُنفد" : `متبقٍ ${left} من ${p.max_per_month}`}
                </span>
              </li>
            );
          })}
        </ul>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- my requests

function MyRequests({ items, timeZone, online, onChanged }: {
  items: RequestItem[]; timeZone: string; online: boolean; onChanged: (text: string, kind: "success" | "error") => void;
}) {
  return (
    <section aria-labelledby="mine-title">
      <h2 id="mine-title" className="section-title">طلباتي</h2>
      {items.length === 0 ? (
        <p className="muted empty">لا توجد طلبات بعد.</p>
      ) : (
        <ul className="req-list">
          {items.map((r) => (
            <li key={r.id}><MyRequestCard item={r} timeZone={timeZone} online={online} onChanged={onChanged} /></li>
          ))}
        </ul>
      )}
    </section>
  );
}

function MyRequestCard({ item, timeZone, online, onChanged }: {
  item: RequestItem; timeZone: string; online: boolean; onChanged: (text: string, kind: "success" | "error") => void;
}) {
  const [busy, setBusy] = useState(false);
  const period = formatPeriod(item, timeZone);
  const steps = visibleSteps(item.steps);

  async function cancel() {
    if (busy || !window.confirm("إلغاء هذا الطلب؟ سيُسحب من مسار الموافقة.")) return;
    setBusy(true);
    try {
      await api.cancelRequest(item.id);
      onChanged("أُلغي الطلب.", "success");
    } catch (e) {
      const code = e instanceof AppError ? e.code : "unknown";
      onChanged(code === "network" ? "لم يصل رد. حدّث الصفحة لترى حالة الطلب." : ERROR_TEXT[code], "error");
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className={`req-card mine ${item.status}`}>
      <header className="req-card-head">
        <span className={`type-ico ${item.type}`} aria-hidden="true"><Icon name={TYPE_ICON[item.type]} /></span>
        <div className="req-head-text">
          <p className="req-title">{requestTitle(item)}{item.days !== null && ` · ${formatDays(item.days)}`}{item.minutes !== null && ` · ${formatMinutes(item.minutes)}`}</p>
          <p className="req-period">{period.day}{period.time && <>{" · "}<span>{period.time}</span></>}</p>
        </div>
        <span className={`chip ${item.status}`}>{STATUS_LABEL[item.status]}</span>
      </header>
      {steps.length > 0 && (
        <ol className="steps" aria-label="مسار الموافقة">
          {steps.map((s) => (
            <li key={s.step_order} className={`step ${s.status}`} title={KIND_LABEL[s.kind]}>
              <span className="step-dot" aria-hidden="true" />
              <span className="step-name">{s.kind === "hr" ? KIND_LABEL.hr : s.approver_name ?? KIND_LABEL[s.kind]}</span>
            </li>
          ))}
        </ol>
      )}
      <p className="req-progress">{progressLine(item)}</p>
      {visibleNote(item) && <p className="req-reason">«{keepDatesTogether(visibleNote(item) ?? "")}»</p>}
      {item.status === "pending" && (
        <button className="btn ghost small cancel" onClick={cancel} disabled={busy || !online}>إلغاء الطلب</button>
      )}
    </article>
  );
}

/** A date like 2026-11-02 inside Arabic text must not be split over two lines (the hyphens allow a break). */
function keepDatesTogether(text: string) {
  return text.split(/(\d{4}-\d{2}-\d{2})/).map((part, i) => (i % 2 ? <bdi key={i}>{part}</bdi> : part));
}

// ---------------------------------------------------------------- new request

const PREVIEW_DELAY_MS = 400;

function NewRequestForm({ initialType, initialDraft, overview, online, onClose, onSent }: {
  initialType: RequestType; initialDraft?: Draft; overview: RequestsOverview; online: boolean; onClose: () => void; onSent: (r: RequestItem) => void;
}) {
  const tz = overview.timezone;
  const ptypes = overview.permission_types;
  const earliest = leaveEarliest(overview);
  const [draft, setDraft] = useState<Draft>(() => clampLeaveDates(initialDraft ?? { ...emptyDraft(overview.today, ptypes[0]), type: initialType }, earliest));
  const ptype = ptypes.find((p) => p.id === draft.permission_type_id) ?? null;
  const [preview, setPreview] = useState<{ sig: string; result: RequestPreview } | null>(null);
  const [previewError, setPreviewError] = useState<{ sig: string; code: AppErrorCode } | null>(null);
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<AppErrorCode | null>(null);
  // One key per request content: a retry of the same content never creates a second request.
  const key = useRef<{ sig: string; key: string } | null>(null);

  const leaveTypes = useMemo(() => overview.balances.map((b) => b.leave_type), [overview.balances]);
  const built = draftToRequest(draft, tz);
  const sig = built.ok ? requestSignature(built.request) : null;

  useEffect(() => {
    if (!built.ok || !online) return;
    const request = built.request;
    const s = requestSignature(request);
    let alive = true;
    const t = setTimeout(async () => {
      try {
        const result = await api.previewRequest(request);
        if (alive) { setPreview({ sig: s, result }); setPreviewError(null); }
      } catch (e) {
        if (alive) setPreviewError({ sig: s, code: e instanceof AppError ? e.code : "unknown" });
      }
    }, PREVIEW_DELAY_MS);
    return () => { alive = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the signature is the content
  }, [sig, online]);

  const set = (patch: Partial<Draft>) => {
    setSendError(null);
    setDraft((d) => {
      const next = { ...d, ...patch };
      if (patch.start_date && next.end_date < patch.start_date) next.end_date = patch.start_date;
      // "Other" request: the employee is not asked for a date; it is today (whatever was picked on the leave form before).
      if (next.type === "other") { next.start_date = overview.today; next.end_date = overview.today; }
      // Switching to a leave starts from an allowed day; typing a date is never moved under the finger (the message tells why).
      return patch.type ? clampLeaveDates(next, earliest) : next;
    });
  };

  const current = preview && preview.sig === sig ? preview.result : null;
  const problem: AppErrorCode | null = !built.ok
    ? (draft.type === "permission" && !permissionTimesFilled(draft)) || (draft.type === "other" && built.error === "reason_required")
      ? null // not filled in yet: no red text
      : built.error
    : draft.type === "leave" && draft.start_date < earliest ? "leave_date_not_allowed"
    : previewError && previewError.sig === sig ? previewError.code : null;
  const canSend = built.ok && current !== null && problem === null && !sending && online;

  async function send() {
    if (!built.ok || !canSend) return;
    if (!key.current || key.current.sig !== sig) key.current = { sig: sig!, key: newRequestId() };
    setSending(true);
    setSendError(null);
    try {
      onSent(await api.submitRequest(key.current.key, built.request));
    } catch (e) {
      setSendError(e instanceof AppError ? e.code : "unknown");
    } finally {
      setSending(false);
    }
  }

  const types: { id: RequestType; label: string }[] = [
    { id: "leave", label: "إجازة" },
    { id: "permission", label: "إذن" },
    { id: "other", label: "طلب آخر" },
  ];

  return (
    <>
    <AppBar title="طلب جديد" onBack={onClose} backDisabled={sending} />
    <main className="container requests">
      <div className="seg" role="radiogroup" aria-label="نوع الطلب">
        {types.map((t) => (
          <button
            key={t.id}
            role="radio"
            aria-checked={draft.type === t.id}
            className={`seg-btn${draft.type === t.id ? " on" : ""}`}
            onClick={() => set({ type: t.id })}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="form card">
        {draft.type === "leave" && (
          <label className="field">
            <span>نوع الإجازة</span>
            <select value={draft.leave_type} onChange={(e) => set({ leave_type: e.target.value as LeaveType })}>
              {leaveTypes.map((t) => <option key={t} value={t}>{LEAVE_LABEL[t]}</option>)}
            </select>
          </label>
        )}

        {draft.type === "permission" ? (
          ptypes.length === 0 ? (
            <p className="muted">لا توجد أنواع أذونات متاحة. تواصل مع إدارة شركتك.</p>
          ) : (
          <>
            <label className="field">
              <span>نوع الإذن</span>
              <select
                value={draft.permission_type_id}
                onChange={(e) => {
                  const p = ptypes.find((x) => x.id === e.target.value)!;
                  const lo = addDays(overview.today, -p.days_back);
                  const hi = addDays(overview.today, p.days_ahead);
                  set({ permission_type_id: p.id, permission_mode: p.mode, date: draft.date < lo || draft.date > hi ? overview.today : draft.date });
                }}
              >
                {ptypes.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </label>
            {ptype && ptype.days_back === 0 && ptype.days_ahead === 0 ? (
              <p className="field-static"><span>اليوم</span> {formatDay(overview.today)}</p>
            ) : (
              <label className="field">
                <span>اليوم</span>
                <input type="date" value={draft.date}
                       min={addDays(overview.today, -(ptype?.days_back ?? 0))} max={addDays(overview.today, ptype?.days_ahead ?? 0)}
                       onChange={(e) => set({ date: e.target.value })} />
              </label>
            )}
            {draft.permission_mode === "range" ? (
              <div className="stack">
                <TimeField label="من الساعة" value={draft.from} step={5} onChange={(v) => set({ from: v })} />
                <TimeField label="إلى الساعة" value={draft.to} step={5} onChange={(v) => set({ to: v })} />
              </div>
            ) : draft.permission_mode === "late_arrival" ? (
              <TimeField label="وقت الوصول" value={draft.to} step={1} onChange={(v) => set({ to: v })} />
            ) : (
              <TimeField label="وقت الخروج" value={draft.from} step={5} onChange={(v) => set({ from: v })} />
            )}
          </>
          )
        ) : draft.type === "leave" ? (
          <div className="two">
            <label className="field">
              <span>من</span>
              <input type="date" value={draft.start_date} min={earliest} max={addDays(overview.today, 365)}
                     onChange={(e) => set({ start_date: e.target.value })} />
            </label>
            <label className="field">
              <span>إلى</span>
              <input type="date" value={draft.end_date} min={draft.start_date} max={addDays(overview.today, 365)}
                     onChange={(e) => set({ end_date: e.target.value })} />
            </label>
          </div>
        ) : null}

        <label className="field">
          <span>{draft.type === "other" ? "ما الذي تطلبه؟" : "السبب (اختياري)"}</span>
          <textarea value={draft.reason} maxLength={500} rows={3} onChange={(e) => set({ reason: e.target.value })}
                    placeholder={draft.type === "other" ? "مثال: شهادة راتب، تعديل بيانات…" : undefined} />
        </label>
      </div>

      {problem && <ProblemLine problem={problem} draft={draft} ptype={ptype} earliest={earliest} />}

      {sendError && (
        <Banner kind="error">{sendError === "network" ? "لم يصل رد من الخادم. اضغط «إرسال الطلب» مرة أخرى — لن يُقدَّم الطلب مرتين." : ERROR_TEXT[sendError]}</Banner>
      )}
      {!online && <Banner kind="warning">لا يوجد اتصال بالإنترنت. أرسل الطلب عند عودة الاتصال.</Banner>}

      <button className="btn primary block send" onClick={send} disabled={!canSend} aria-busy={sending}>
        {sending ? "جارٍ الإرسال…" : "إرسال الطلب"}
      </button>
    </main>
    </>
  );
}

/** Server errors about a permission, worded with the rules of its type. */
function permissionErrorText(code: AppErrorCode, p: PermissionUsage | null): string {
  if (p && code === "permission_too_long" && p.max_minutes !== null) return `أطول من المسموح لهذا الإذن (${formatMinutes(p.max_minutes)} كحد أقصى في المرة).`;
  if (p && code === "permission_limit" && p.max_per_month !== null) return `استنفدت هذا الإذن هذا الشهر (${formatTimes(p.max_per_month)} في الشهر، والطلبات المعلّقة محسوبة).`;
  if (p && code === "outside_window") {
    if (p.days_back === 0 && p.days_ahead === 0) return "هذا الإذن يُطلب في نفس اليوم فقط.";
    return `هذا الإذن يُطلب من ${formatDays(p.days_back)} قبل اليوم إلى ${formatDays(p.days_ahead)} بعده.`;
  }
  return ERROR_TEXT[code];
}

/** The only line under the form: why the request cannot be sent yet. Nothing is shown while all is well. */
function ProblemLine({ problem, draft, ptype, earliest }: { problem: AppErrorCode; draft: Draft; ptype: PermissionUsage | null; earliest: string }) {
  const text = problem === "leave_date_not_allowed" ? `لا يمكن طلب إجازة تبدأ قبل ${formatDay(earliest)} حسب قواعد الشركة.`
    : problem === "network" ? "تعذّر التحقق من الطلب الآن. تحقق من الاتصال."
    : draft.type === "permission" ? permissionErrorText(problem, ptype) : ERROR_TEXT[problem];
  return <p className="preview bad" role="alert">{text}</p>;
}
