// 12-hour clock with ص (morning) / م (afternoon), Western digits. The server and the forms keep using 24-hour "HH:MM";
// this file is only for what the employee reads and picks. Pure functions, unit-tested.

export type Period = "ص" | "م";

export function to12(h24: number, m: number): { h: number; mm: string; period: Period } {
  return { h: h24 % 12 === 0 ? 12 : h24 % 12, mm: String(m).padStart(2, "0"), period: h24 < 12 ? "ص" : "م" };
}

/** "8:05 ص" */
export function format12(h24: number, m: number): string {
  const t = to12(h24, m);
  return `${t.h}:${t.mm} ${t.period}`;
}

/** 12-hour pieces (hour 1-12, minutes "00"-"59", period) -> 24-hour "HH:MM". */
export function from12(h: number, mm: string, period: Period): string {
  const h24 = (h % 12) + (period === "م" ? 12 : 0);
  return `${String(h24).padStart(2, "0")}:${mm}`;
}

/** Hour (0-23), minute and second of an instant on the wall clock of a time zone. */
export function zonedHMS(iso: string, timeZone: string): { h: number; m: number; s: number } {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" })
      .formatToParts(new Date(iso))
      .map((x) => [x.type, x.value]),
  );
  return { h: Number(p.hour), m: Number(p.minute), s: Number(p.second) };
}

/** The live clock in three pieces: "8:05", "09", "م". */
export function clockParts(iso: string, timeZone: string): { hm: string; ss: string; period: Period } {
  const { h, m, s } = zonedHMS(iso, timeZone);
  const t = to12(h, m);
  return { hm: `${t.h}:${t.mm}`, ss: String(s).padStart(2, "0"), period: t.period };
}
