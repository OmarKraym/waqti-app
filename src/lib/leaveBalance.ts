// Annual leave balance texts (phase 18a: earned day by day, carried over, HR may change the days taken).
import { formatDays } from "./requests";
import type { CustomKind, LeaveBalance, RequestItem, RequestPreview } from "./types";

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

/** Under the leave type list, for a kind the administration added: what is left of its days this year (null = nothing to say). */
export function kindBalanceLine(b: LeaveBalance | null): string | null {
  if (!b) return null;
  if (b.entitled === null) return "أيام هذا النوع غير محدودة.";
  if (b.entitled === 0) return "لا أيام مخصصة لك من هذا النوع هذه السنة.";
  const left = Math.max(0, b.remaining ?? 0);
  return `المتبقي لك: ${left === 0 ? "لا شيء" : formatDays(left)} من ${formatDays(b.entitled)} هذه السنة.`;
}

/** With the other types of the year («حج: 4 أيام هذه السنة»): the kinds the administration added that were used or are waiting. */
export function customUsedTexts(kinds: CustomKind[]): string[] {
  return kinds
    .filter((k) => k.family === "leave" && k.balance && k.balance.used + k.balance.pending > 0)
    .map((k) => `${k.name}: ${formatDays(k.balance!.used + k.balance!.pending)} هذه السنة`);
}

export interface AnnualExplain {
  /** One sentence: the year is earned day by day. */
  lead: string;
  /** The sum, line by line: what was earned (+), carried (+), taken (−), and what is left (total). */
  rows: { label: string; value: string; sign: "plus" | "minus" | "total" }[];
  /** What is still to come this year; null when the whole year is earned. */
  note: string | null;
}

const num = (n: number) => String(Math.round(n * 10) / 10);

/**
 * Why the annual balance is what it is, for the dialog that opens when the number is tapped. The same sum as the server
 * (phase 18a): earned up to as_of (+ carried) − used − used outside the app − waiting = remaining. Null on an older server.
 */
export function annualExplain(b: LeaveBalance): AnnualExplain | null {
  if (b.earned === undefined || b.entitled === null || b.remaining === null) return null;
  const carried = b.carried ?? 0;
  const outside = b.used_outside ?? 0;
  const yearDays = b.entitled - carried;
  const earnedYear = b.earned - carried;
  const when = b.as_of
    ? new Intl.DateTimeFormat("ar-LY", { day: "numeric", month: "long", timeZone: "UTC", numberingSystem: "latn" }).format(new Date(`${b.as_of}T12:00:00Z`))
    : "اليوم";
  const rows: AnnualExplain["rows"] = [{ label: `ما اكتسبته حتى ${when}`, value: formatDays(earnedYear), sign: "plus" }];
  if (carried > 0) rows.push({ label: "مرحّلة من السنة الماضية", value: formatDays(carried), sign: "plus" });
  if (b.used > 0) rows.push({ label: "مستخدمة", value: formatDays(b.used), sign: "minus" });
  if (outside > 0) rows.push({ label: "سجّلتها الإدارة خارج التطبيق", value: formatDays(outside), sign: "minus" });
  if (b.pending > 0) rows.push({ label: "قيد الموافقة", value: formatDays(b.pending), sign: "minus" });
  rows.push({ label: "المتاح لك الآن", value: formatDays(b.remaining), sign: "total" });
  const rest = b.entitled - b.earned;
  return {
    lead: `رصيدك السنوي ${formatDays(yearDays)} لا يُعطى دفعة واحدة، بل يُكتسب يومًا بيوم على مدار السنة (نحو ${num(yearDays / 12)} يوم كل شهر).`,
    rows,
    note: rest > 0 ? `الباقي (${formatDays(rest)}) يُضاف تدريجيًا حتى نهاية السنة.` : null,
  };
}
