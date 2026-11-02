// Light / dark / auto theme. The choice lives on the phone (not per account): it is about the screen, not the person.
// The CSS does the colours (src/styles.css): "light" and "dark" set data-theme on <html>; "auto" sets nothing and the
// CSS follows the phone's setting by itself. public/theme-init.js applies the saved choice before the first paint.

export type ThemeChoice = "auto" | "light" | "dark";
export type ResolvedTheme = "light" | "dark";

export const THEME_KEY = "waqti-theme";

/** Browser bar colour per theme. Must equal --bg in styles.css (src/lib/palette.test.ts checks it). */
export const THEME_COLOR: Record<ResolvedTheme, string> = { light: "#f2f7fb", dark: "#0b1520" };

export const THEME_CHOICES: readonly ThemeChoice[] = ["auto", "light", "dark"];
export const THEME_LABEL: Record<ThemeChoice, string> = { auto: "تلقائي", light: "فاتح", dark: "داكن" };
export const THEME_HINT: Record<ThemeChoice, string> = {
  auto: "يتبع إعداد هاتفك (فاتح أو داكن).",
  light: "مظهر فاتح دائمًا.",
  dark: "مظهر داكن دائمًا.",
};

/** Anything unknown (empty, old value, tampered) means "auto". */
export function parseChoice(raw: unknown): ThemeChoice {
  return raw === "light" || raw === "dark" ? raw : "auto";
}

export function resolveTheme(choice: ThemeChoice, systemDark: boolean): ResolvedTheme {
  if (choice === "auto") return systemDark ? "dark" : "light";
  return choice;
}

/** The data-theme value for <html>; null = no attribute (the CSS follows the phone). */
export function attributeFor(choice: ThemeChoice): ResolvedTheme | null {
  return choice === "auto" ? null : choice;
}

export function readChoice(storage: Pick<Storage, "getItem"> | null): ThemeChoice {
  try {
    return parseChoice(storage?.getItem(THEME_KEY));
  } catch {
    return "auto";
  }
}

/** "auto" is the default, so it is saved as "nothing". */
export function saveChoice(storage: Pick<Storage, "setItem" | "removeItem"> | null, choice: ThemeChoice): void {
  try {
    if (choice === "auto") storage?.removeItem(THEME_KEY);
    else storage?.setItem(THEME_KEY, choice);
  } catch {
    // private mode or full storage: the choice then lasts until the app closes
  }
}

function safeStorage(): Storage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

function systemPrefersDark(): boolean {
  return typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;
}

/** Puts a choice on the page: the data-theme attribute and the browser bar colour. Returns what is shown. */
export function applyTheme(choice: ThemeChoice, doc: Document = document): ResolvedTheme {
  const attr = attributeFor(choice);
  if (attr) doc.documentElement.setAttribute("data-theme", attr);
  else doc.documentElement.removeAttribute("data-theme");
  const shown = resolveTheme(choice, systemPrefersDark());
  doc.querySelector('meta[name="theme-color"]')?.setAttribute("content", THEME_COLOR[shown]);
  return shown;
}

/** The saved choice (or the page was never changed); in auto, follows the phone when its setting changes. */
export function initTheme(): void {
  applyTheme(readChoice(safeStorage()));
  if (typeof matchMedia !== "function") return;
  const query = matchMedia("(prefers-color-scheme: dark)");
  const onChange = () => void applyTheme(readChoice(safeStorage()));
  if (typeof query.addEventListener === "function") query.addEventListener("change", onChange);
  else query.addListener?.(onChange); // Safari before 14
}

/** For the profile screen: the saved choice, and a function that saves and applies a new one. */
export function currentChoice(): ThemeChoice {
  return readChoice(safeStorage());
}

export function chooseTheme(choice: ThemeChoice): void {
  saveChoice(safeStorage(), choice);
  applyTheme(choice);
}
