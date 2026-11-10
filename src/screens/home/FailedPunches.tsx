import { formatDate, formatTime } from "../../lib/attendance";
import { ERROR_TEXT } from "../../lib/errors";
import type { QueuedPunch } from "../../lib/offlineQueue";
import { Button, Icon } from "../../components";

/** Punches saved on the phone that the server refused: listed for the company to correct, then dismissed. */
export function FailedPunches({ failed, timeZone, onDismiss }: { failed: QueuedPunch[]; timeZone: string; onDismiss: () => void }) {
  if (failed.length === 0) return null;
  return (
    <section className="failed" role="alert">
      <h3 className="section__title"><Icon name="alert" className="icon--inline" />تسجيلات لم يقبلها الخادم</h3>
      <ul className="failed__list">
        {failed.map((q) => (
          <li key={q.request_id} className="failed__item">
            <span className="failed__what">
              {q.action === "check_in" ? "حضور" : "انصراف"} {formatDate(q.offline_at, timeZone)}{" "}
              <span dir="ltr">{formatTime(q.offline_at, timeZone)}</span>
            </span>
            <span className="failed__reason">{ERROR_TEXT[q.error_code ?? "unknown"]}</span>
          </li>
        ))}
      </ul>
      <p className="hint">هذه التسجيلات لم تُحسب. تواصل مع إدارة شركتك لتصحيحها.</p>
      <Button variant="ghost" block onClick={onDismiss}>فهمت، إخفاء</Button>
    </section>
  );
}
