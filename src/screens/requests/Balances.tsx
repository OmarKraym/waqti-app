import {
  LEAVE_LABEL,
  formatDays,
  permissionLeft,
} from "../../lib/requests";
import type { PermissionUsage, RequestsOverview } from "../../lib/types";
import { annualCard, annualExplain, customUsedTexts, type AnnualExplain } from "../../lib/leaveBalance";
import { useState } from "react";
import { Button, Icon, Modal } from "../../components";


// ---------------------------------------------------------------- balances

/** «كيف حُسب رصيدك؟»: the sum behind the annual number, short, line by line. */
function ExplainDialog({ e, onClose }: { e: AnnualExplain; onClose: () => void }) {
  return (
    <Modal title="كيف حُسب رصيدك؟" onClose={onClose} sheet>
      <p className="modal__text">{e.lead}</p>
      <dl className="explain">
        {e.rows.map((r) => (
          <div key={r.label} className={`explain__row explain__row--${r.sign}`}>
            <dt>{r.label}</dt>
            <dd>{r.sign === "plus" ? "+ " : r.sign === "minus" ? "− " : ""}{r.value}</dd>
          </div>
        ))}
      </dl>
      {e.note && <p className="explain__note">{e.note}</p>}
      <div className="modal__actions">
        <Button variant="primary" block onClick={onClose}>فهمت</Button>
      </div>
    </Modal>
  );
}

export function Balances({ overview }: { overview: RequestsOverview }) {
  const [explaining, setExplaining] = useState(false);
  const annual = overview.balances.find((b) => b.leave_type === "annual");
  const others = [
    ...overview.balances.filter((b) => b.leave_type !== "annual" && (b.used > 0 || b.pending > 0))
      .map((b) => `${LEAVE_LABEL[b.leave_type]}: ${formatDays(b.used + b.pending)} هذه السنة`),
    ...customUsedTexts(overview.custom_kinds ?? []),
  ];
  if (!(annual && annual.remaining !== null) && others.length === 0) return null;
  const entitled = annual?.entitled ?? 0;
  const pct = (n: number) => (entitled > 0 ? Math.min(100, Math.max(0, (n / entitled) * 100)) : 0);
  const card = annual ? annualCard(annual) : null;
  const explain = annual ? annualExplain(annual) : null;
  return (
    <section className="balances" aria-label="أرصدتي">
      {annual && annual.remaining !== null && card && (
        <div className="balance balance--annual">
          {explain ? (
            // The number opens the explanation (why 27 today and not 30).
            <button type="button" className="balance__explain" onClick={() => setExplaining(true)} aria-haspopup="dialog">
              <span className="balance__label">الإجازة السنوية</span>
              <span className="balance__value">
                {formatDays(card.value)}
                <span className="balance__why"><Icon name="info" />كيف حُسب؟</span>
              </span>
            </button>
          ) : (
            <>
              <span className="balance__label">الإجازة السنوية</span>
              <span className="balance__value">{formatDays(card.value)}</span>
            </>
          )}
          <span className="balance__sub">{card.sub}{annual.pending > 0 && ` · ${formatDays(annual.pending)} قيد الموافقة`}</span>
          {entitled > 0 && (
            // An SVG bar: the widths are attributes, not inline styles. x runs left to right, so the used part is drawn
            // from the right edge (the start of the line in Arabic), then the pending part next to it.
            <svg className="balance__bar" viewBox="0 0 100 8" preserveAspectRatio="none" role="img"
              aria-label={`مستخدم ${formatDays(annual.used)} وقيد الموافقة ${formatDays(annual.pending)} من ${formatDays(entitled)}`}>
              <rect className="balance__used" x={100 - pct(annual.used)} width={pct(annual.used)} height="8" />
              <rect className="balance__pending" x={100 - pct(annual.used) - pct(annual.pending)} width={pct(annual.pending)} height="8" />
            </svg>
          )}
          <dl className="balance__stats">
            {card.stats.map((st) => <div key={st.label}><dt>{st.label}</dt><dd>{st.value}</dd></div>)}
          </dl>
        </div>
      )}
      {explaining && explain && <ExplainDialog e={explain} onClose={() => setExplaining(false)} />}
      {others.length > 0 && (
        <p className="balances__others">
          {others.join(" · ")}
        </p>
      )}
    </section>
  );
}

export function PermissionUsage({ overview }: { overview: RequestsOverview }) {
  if (overview.permission_types.length === 0) return null;
  return (
    <section className="perms" aria-labelledby="perm-title">
      <h2 id="perm-title" className="section__title">الأذونات هذا الشهر</h2>
      <div className="balance">
        <ul className="perm-usage">
          {overview.permission_types.map((p) => {
            const left = permissionLeft(p);
            const share = left === null || !p.max_per_month ? 1 : left / p.max_per_month;
            return (
              <li key={p.id}>
                <span className="perm-usage__name">{p.name}</span>
                <span className={`perm-usage__left${left === 0 ? " perm-usage__left--none" : share < 0.5 ? " perm-usage__left--low" : ""}`}>
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
