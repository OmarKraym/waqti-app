import { useState } from "react";
import { api } from "../../lib/client";
import { AppError, ERROR_TEXT, type AppErrorCode } from "../../lib/errors";
import {
  formatDays,
  formatMinutes,
  formatPeriod,
  formatTimes,
  remainingAfter,
  requestTitle,
  visibleSteps,
} from "../../lib/requests";
import type { InboxItem } from "../../lib/types";
import { Button, Icon } from "../../components";

import { TYPE_ICON } from "./shared";

// ---------------------------------------------------------------- waiting for my decision

export function Inbox({ items, timeZone, online, onDone }: {
  items: InboxItem[]; timeZone: string; online: boolean; onDone: (text: string, kind: "success" | "error") => void;
}) {
  return (
    <section  aria-labelledby="inbox-title">
      <h2 id="inbox-title" className="section__title">بانتظار موافقتك <span className="count">{items.length}</span></h2>
      <ul className="req-list">
        {items.map((it) => (
          <li key={it.approval_id}><InboxCard item={it} timeZone={timeZone} online={online} onDone={onDone} /></li>
        ))}
      </ul>
    </section>
  );
}

export function InboxCard({ item, timeZone, online, onDone }: {
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
    <article className="req-card req-card--approve">
      <header className="req-card__head">
        <span className="mini-avatar" aria-hidden="true">{item.employee.full_name.trim().charAt(0)}</span>
        <div className="req-card__head-text">
          <p className="req-card__who u-truncate">{item.employee.full_name}</p>
          <p className="req-card__title">{requestTitle(item)}{item.days !== null && ` · ${formatDays(item.days)}`}{item.minutes !== null && ` · ${formatMinutes(item.minutes)}`}</p>
        </div>
        <span className="req-card__step-of">الخطوة {visibleSteps(item.steps).findIndex((s) => s.step_order === item.my_step) + 1} من {item.step_count}</span>
      </header>
      {item.date_mode !== "none" && (
        <p className="req-card__period"><Icon name={TYPE_ICON[item.type]} className="icon--inline" />{period.day}{period.time && <>{" · "}<span>{period.time}</span></>}</p>
      )}
      {item.reason && <p className="req-card__reason">«{item.reason}»</p>}
      {item.balance && item.balance.entitled !== null && (
        <p className="req-card__meta">رصيده المتبقي بعد الموافقة: <strong>{formatDays(Math.max(after ?? 0, 0))}</strong> من {formatDays(item.balance.entitled)}</p>
      )}
      {item.permission && (
        <p className="req-card__meta">
          {item.permission.max_per_month === null
            ? `هذا النوع بلا حد لعدد المرات (طلب ${formatTimes(item.permission.used + item.permission.pending + 1)} هذا الشهر).`
            : <>استخدم هذا الشهر <strong>{item.permission.used + item.permission.pending}</strong> من {item.permission.max_per_month} قبل هذا الطلب.</>}
        </p>
      )}
      {err && <p className="form__error" role="alert">{err === "network" ? "لم يصل رد. حاول مرة أخرى؛ لن يُسجّل القرار مرتين." : ERROR_TEXT[err]}</p>}
      {rejecting ? (
        <div className="req-card__reject">
          <label className="field">
            <span>سبب الرفض (يراه الموظف، اختياري)</span>
            <textarea value={reason} maxLength={500} rows={2} onChange={(e) => setReason(e.target.value)} />
          </label>
          <div className="actions">
            <Button onClick={() => setRejecting(false)} disabled={busy}>تراجع</Button>
            <Button variant="danger" onClick={() => decide("reject")} disabled={busy || !online} aria-busy={busy}>تأكيد الرفض</Button>
          </div>
        </div>
      ) : (
        <footer className="req-card__decide">
          <Button variant="danger-soft" size="sm" onClick={() => setRejecting(true)} disabled={busy || !online}><Icon name="close" />رفض</Button>
          <Button variant="approve" size="sm" onClick={() => decide("approve")} disabled={busy || !online} aria-busy={busy}>
            <Icon name="tick" />{busy ? "جارٍ الإرسال…" : "موافقة"}
          </Button>
        </footer>
      )}
    </article>
  );
}
