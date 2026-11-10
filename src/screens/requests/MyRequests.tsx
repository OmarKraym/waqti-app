import { useState } from "react";
import { api } from "../../lib/client";
import { AppError, ERROR_TEXT } from "../../lib/errors";
import {
  STATUS_LABEL,
  formatDays,
  formatMinutes,
  formatPeriod,
  progressLine,
  visibleNote,
  requestTitle,
  visibleSteps,
  KIND_LABEL,
} from "../../lib/requests";
import type { RequestItem } from "../../lib/types";
import { chargedLine } from "../../lib/leaveBalance";
import { Button, Chip, ConfirmDialog, EmptyState, Icon } from "../../components";

import { TYPE_ICON } from "./shared";

// ---------------------------------------------------------------- my requests

export function MyRequests({ items, timeZone, online, onChanged }: {
  items: RequestItem[]; timeZone: string; online: boolean; onChanged: (text: string, kind: "success" | "error") => void;
}) {
  return (
    <section aria-labelledby="mine-title">
      <h2 id="mine-title" className="section__title">طلباتي</h2>
      {items.length === 0 ? (
        <EmptyState>لا توجد طلبات بعد</EmptyState>
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

export function MyRequestCard({ item, timeZone, online, onChanged }: {
  item: RequestItem; timeZone: string; online: boolean; onChanged: (text: string, kind: "success" | "error") => void;
}) {
  const [busy, setBusy] = useState(false);
  const period = formatPeriod(item, timeZone);
  const steps = visibleSteps(item.steps);

  const [asking, setAsking] = useState(false);
  async function cancel() {
    if (busy) return;
    setBusy(true);
    try {
      await api.cancelRequest(item.id);
      onChanged("أُلغي الطلب.", "success");
    } catch (e) {
      const code = e instanceof AppError ? e.code : "unknown";
      onChanged(code === "network" ? "لم يصل رد. حدّث الصفحة لترى حالة الطلب." : ERROR_TEXT[code], "error");
    } finally {
      setBusy(false);
      setAsking(false);
    }
  }

  return (
    <article className={`req-card req-card--mine req-card--${item.status}`}>
      <header className="req-card__head">
        <span className={`type-ico type-ico--${item.type}`} aria-hidden="true"><Icon name={TYPE_ICON[item.type]} /></span>
        <div className="req-card__head-text">
          <p className="req-card__title">{requestTitle(item)}{item.days !== null && ` · ${formatDays(item.days)}`}{item.minutes !== null && ` · ${formatMinutes(item.minutes)}`}</p>
          {item.date_mode !== "none" && <p className="req-card__period">{period.day}{period.time && <>{" · "}<span>{period.time}</span></>}</p>}
        </div>
        <Chip status={item.status}>{STATUS_LABEL[item.status]}</Chip>
      </header>
      {steps.length > 0 && (
        <ol className="steps" aria-label="مسار الموافقة">
          {steps.map((s) => (
            <li key={s.step_order} className={`steps__step steps__step--${s.status}`} title={KIND_LABEL[s.kind]}>
              <span className="steps__dot" aria-hidden="true" />
              <span className="steps__name">{s.kind === "hr" ? KIND_LABEL.hr : s.approver_name ?? KIND_LABEL[s.kind]}</span>
            </li>
          ))}
        </ol>
      )}
      <p className="req-card__progress">{progressLine(item)}</p>
      {chargedLine(item) && <p className="req-card__progress">{chargedLine(item)}</p>}
      {visibleNote(item) && <p className="req-card__reason">«{keepDatesTogether(visibleNote(item) ?? "")}»</p>}
      {item.status === "pending" && (
        <Button variant="ghost" size="sm" className="req-card__cancel" onClick={() => setAsking(true)} disabled={busy || !online}>إلغاء الطلب</Button>
      )}
      {asking && (
        <ConfirmDialog title="إلغاء الطلب" confirmLabel="إلغاء الطلب" danger busy={busy}
          onConfirm={() => void cancel()} onCancel={() => setAsking(false)}>
          إلغاء هذا الطلب؟ سيُسحب من مسار الموافقة.
        </ConfirmDialog>
      )}
    </article>
  );
}

/** A date like 2026-11-02 inside Arabic text must not be split over two lines (the hyphens allow a break). */
function keepDatesTogether(text: string) {
  return text.split(/(\d{4}-\d{2}-\d{2})/).map((part, i) => (i % 2 ? <bdi key={i}>{part}</bdi> : part));
}
