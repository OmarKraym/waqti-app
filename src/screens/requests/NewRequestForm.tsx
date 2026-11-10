import { ERROR_TEXT, type AppErrorCode } from "../../lib/errors";
import {
  LEAVE_LABEL,
  addDays,
  formatDays,
  formatMinutes,
  formatDay,
  formatTimes,
  type Draft,
} from "../../lib/requests";
import type { LeaveType, PermissionUsage, RequestItem, RequestType, RequestsOverview } from "../../lib/types";
import { kindBalanceLine } from "../../lib/leaveBalance";
import { useNewRequest } from "../../hooks/useNewRequest";
import { AppBar, Banner, Button, TimeField } from "../../components";


// ---------------------------------------------------------------- new request

export function NewRequestForm({ initialType, initialDraft, overview, online, onClose, onSent }: {
  initialType: RequestType; initialDraft?: Draft; overview: RequestsOverview; online: boolean; onClose: () => void; onSent: (r: RequestItem) => void;
}) {
  const { ptypes, earliest, draft, ptype, leaveTypes, leaveKinds, otherKinds, kind, problem, over, canSend, sending, sendError, set, send } =
    useNewRequest({ initialType, initialDraft, overview, online, onSent });
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
            className={`seg__btn${draft.type === t.id ? " is-active" : ""}`}
            onClick={() => set({ type: t.id })}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="form card">
        {draft.type === "leave" && (
          <>
            <label className="field">
              <span>نوع الإجازة</span>
              <select
                value={draft.custom_kind_id ? `custom:${draft.custom_kind_id}` : draft.leave_type}
                onChange={(e) => {
                  const v = e.target.value;
                  if (v.startsWith("custom:")) set({ leave_type: "custom", custom_kind_id: v.slice("custom:".length) });
                  else set({ leave_type: v as LeaveType, custom_kind_id: "" });
                }}
              >
                {leaveTypes.map((t) => <option key={t} value={t}>{LEAVE_LABEL[t]}</option>)}
                {leaveKinds.length > 0 && (
                  <optgroup label="إجازات أخرى">
                    {leaveKinds.map((k) => <option key={k.id} value={`custom:${k.id}`}>{k.name}</option>)}
                  </optgroup>
                )}
              </select>
            </label>
            {kind && kindBalanceLine(kind.balance) && <p className="hint">{kindBalanceLine(kind.balance)}</p>}
          </>
        )}

        {draft.type === "other" && otherKinds.length > 0 && (
          <label className="field">
            <span>النوع</span>
            <select value={draft.custom_kind_id} onChange={(e) => set({ custom_kind_id: e.target.value })}>
              <option value="">طلب آخر</option>
              {otherKinds.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
            </select>
          </label>
        )}

        {draft.type === "permission" ? (
          ptypes.length === 0 ? (
            <p className="u-muted">لا توجد أنواع أذونات متاحة. تواصل مع إدارة شركتك.</p>
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
              <p className="field--static"><span>اليوم</span> {formatDay(overview.today)}</p>
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
        ) : kind && kind.date_mode === "single" ? (
          <label className="field">
            <span>التاريخ</span>
            <input type="date" value={draft.start_date} min={addDays(overview.today, -30)} max={addDays(overview.today, 365)}
                   onChange={(e) => set({ start_date: e.target.value })} />
          </label>
        ) : kind && kind.date_mode === "range" ? (
          <div className="two">
            <label className="field">
              <span>من</span>
              <input type="date" value={draft.start_date} min={addDays(overview.today, -30)} max={addDays(overview.today, 365)}
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
          <span>{draft.type === "other" ? (kind ? "تفاصيل الطلب" : "ما الذي تطلبه؟") : over || kind?.reason_required ? "السبب (مطلوب)" : "السبب (اختياري)"}</span>
          <textarea value={draft.reason} maxLength={500} rows={3} onChange={(e) => set({ reason: e.target.value })}
                    placeholder={draft.type === "other" && !kind ? "مثال: شهادة راتب، تعديل بيانات…" : undefined} />
        </label>
      </div>

      {problem && <ProblemLine problem={problem} draft={draft} ptype={ptype} earliest={earliest} />}
      {!problem && over && <p className="preview preview--warn" role="status">{over}</p>}

      {sendError && (
        <Banner kind="error">{sendError === "network" ? "لم يصل رد من الخادم. اضغط «إرسال الطلب» مرة أخرى — لن يُقدَّم الطلب مرتين." : ERROR_TEXT[sendError]}</Banner>
      )}
      {!online && <Banner kind="warning">لا يوجد اتصال بالإنترنت. أرسل الطلب عند عودة الاتصال.</Banner>}

      <Button variant="primary" block send onClick={send} disabled={!canSend} aria-busy={sending}>
        {sending ? "جارٍ الإرسال…" : "إرسال الطلب"}
      </Button>
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
export function ProblemLine({ problem, draft, ptype, earliest }: { problem: AppErrorCode; draft: Draft; ptype: PermissionUsage | null; earliest: string }) {
  const text = problem === "leave_date_not_allowed" ? `لا يمكن طلب إجازة تبدأ قبل ${formatDay(earliest)} حسب قواعد الشركة.`
    : problem === "network" ? "تعذّر التحقق من الطلب الآن. تحقق من الاتصال."
    : draft.type === "permission" ? permissionErrorText(problem, ptype) : ERROR_TEXT[problem];
  return <p className="preview preview--bad" role="alert">{text}</p>;
}
