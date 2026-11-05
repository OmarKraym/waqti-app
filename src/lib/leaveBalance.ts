// Annual leave balance texts (phase 18a: earned day by day, carried over, HR may change the days taken).
import { formatDays } from "./requests";
import type { LeaveBalance, RequestItem, RequestPreview } from "./types";

export interface AnnualCard {
  value: number;
  sub: string;
  stats: { label: string; value: string }[];
}

/** The big annual card: what can be taken now, and the year. Older servers (no `earned`) keep the old wording. */
export function annualCard(b: LeaveBalance): AnnualCard {
  const entitled = b.entitled ?? 0;
  const value = b.remaining ?? 0;
  const carried = b.carried ?? 0;
  const third = carried > 0
    ? { label: "مرحّلة من السنة الماضية", value: formatDays(carried) }
    : { label: b.earned === undefined ? "الرصيد الكلي" : "رصيد السنة", value: formatDays(entitled) };
  return {
    value,
    sub: b.earned === undefined ? `متبقٍ من ${formatDays(entitled)}` : `متاح حتى اليوم · ${formatDays(entitled)} للسنة كاملة`,
    stats: [
      { label: "مستخدمة", value: formatDays(b.used) },
      { label: "قيد الموافقة", value: formatDays(b.pending) },
      third,
    ],
  };
}

/** Under the form when a leave is more than the balance: allowed with a reason. */
export function overBalanceLine(p: Pick<RequestPreview, "days" | "balance" | "over_balance"> | null): string | null {
  if (!p || !p.over_balance || p.days === null) return null;
  const left = Math.max(0, p.balance?.remaining ?? 0);
  return `طلبك (${formatDays(p.days)}) أكثر من رصيدك المتاح (${formatDays(left)}). اكتب السبب، والإدارة تقرر.`;
}

/** On a request: the days HR took from the balance, when different from the days asked. */
export function chargedLine(r: Pick<RequestItem, "type" | "days"> & { charged_days?: number | null }): string | null {
  if (r.type !== "leave" || r.charged_days === null || r.charged_days === undefined) return null;
  return `خُصم من الرصيد: ${r.charged_days === 0 ? "لا شيء" : formatDays(r.charged_days)}`;
}
