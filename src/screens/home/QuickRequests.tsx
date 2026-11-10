import type { RequestType } from "../../lib/types";
import { Icon } from "../../components";

/** Shortcuts to a new request, with the type already chosen. */
export function QuickRequests({ online, onNewRequest }: { online: boolean; onNewRequest: (type: RequestType) => void }) {
  return (
    <section className="quick" aria-labelledby="quick-title">
      <h3 id="quick-title" className="section__title">طلب جديد</h3>
      <div className="quick__row">
        <button className="quick__btn" onClick={() => onNewRequest("leave")} disabled={!online}>
          <Icon name="calendar" />إجازة
        </button>
        <button className="quick__btn" onClick={() => onNewRequest("permission")} disabled={!online}>
          <Icon name="clock" />إذن
        </button>
        <button className="quick__btn" onClick={() => onNewRequest("other")} disabled={!online}>
          <Icon name="doc" />طلب آخر
        </button>
      </div>
    </section>
  );
}
