import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { THEME_COLOR } from "./theme";

// Guards for src/styles.css: both dark blocks stay identical, every colour token exists in both themes, the main colour
// pairs are readable (WCAG) in light and dark, and the browser-bar colours match the page colour.

const css = readFileSync(new URL("../styles.css", import.meta.url), "utf8");

function blockAt(start: number): string {
  const open = css.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) return css.slice(open + 1, i);
  }
  throw new Error("unbalanced braces in styles.css");
}

function tokens(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of body.matchAll(/(--[\w-]+):\s*([^;]+);/g)) out[m[1]] = m[2].trim();
  return out;
}

function find(selector: string, from = 0): number {
  const i = css.indexOf(selector, from);
  if (i < 0) throw new Error(`styles.css has no "${selector}"`);
  return i;
}

const light = tokens(blockAt(find(":root {")));
const darkChosen = tokens(blockAt(find(':root[data-theme="dark"] {')));
const darkAuto = tokens(blockAt(find(':root:not([data-theme="light"]):not([data-theme="dark"]) {', find("@media (prefers-color-scheme: dark)"))));
const themes = { light, dark: { ...light, ...darkChosen } } as const;

// ---- WCAG contrast
const hex = (v: string) => (/^#[0-9a-f]{6}$/i.test(v) ? v : null);
function channel(c: number) {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}
function luminance(h: string) {
  const n = parseInt(h.slice(1), 16);
  return 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255);
}
function contrast(a: string, b: string) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

describe("styles.css tokens", () => {
  it("the two dark blocks are identical", () => {
    expect(Object.keys(darkChosen).length).toBeGreaterThan(30);
    expect(darkAuto).toEqual(darkChosen);
  });

  it("every colour token of the light theme has a dark value (only type, space and shape are shared)", () => {
    const shared = /^--(font-|fs-|s\d|r-|h-|gutter)/;
    const missing = Object.keys(light).filter((k) => !shared.test(k) && !(k in darkChosen));
    expect(missing).toEqual([]);
    const extra = Object.keys(darkChosen).filter((k) => !(k in light));
    expect(extra).toEqual([]);
  });

  it("no second .switch rule (two of them once broke the notification switches)", () => {
    expect(css.match(/^\.switch \{/gm)?.length).toBe(1);
  });

  it("the browser-bar colours are the page colour", () => {
    expect(THEME_COLOR.light).toBe(light["--bg"]);
    expect(THEME_COLOR.dark).toBe(themes.dark["--bg"]);
    const init = readFileSync(new URL("../../public/theme-init.js", import.meta.url), "utf8");
    expect(init).toContain(THEME_COLOR.light);
    expect(init).toContain(THEME_COLOR.dark);
  });
});

/** [foreground token, background token, minimum ratio, what it is]. 4.5 = normal text, 3 = big text and non-text. */
const PAIRS: Array<[string, string, number, string]> = [
  ["--text", "--bg", 4.5, "body text on the page"],
  ["--text", "--surface", 4.5, "body text on a card"],
  ["--text-2", "--bg", 4.5, "secondary text on the page"],
  ["--text-2", "--surface", 4.5, "secondary text on a card"],
  ["--text-2", "--sunken", 4.5, "secondary text on a chip"],
  ["--line-strong", "--surface", 3, "input borders and the switch track (off)"],
  ["--in", "--surface", 3, "the switch track (on)"],
  ["#ffffff", "--ink", 4.5, "primary button"],
  ["#ffffff", "--in", 4.5, "check-in button, send button"],
  ["#ffffff", "--punch-out", 4.5, "check-out button"],
  ["#ffffff", "--punch-out-hover", 4.5, "check-out button, pressed or hovered"],
  ["#ffffff", "--danger", 4.5, "delete button"],
  ["#ffffff", "--disabled-fill", 3, "disabled punch button"],
  ["--ink-fg", "--surface", 4.5, "brand-coloured text on a card"],
  ["--ink-fg", "--ink-tint", 4.5, "brand-coloured text on its tint"],
  ["--in-text", "--in-tint", 4.5, "green chip, approved"],
  ["--in-text", "--in-wash", 4.5, "green message"],
  ["--in-text", "--surface", 4.5, "green text on a card"],
  ["--out-text", "--out-tint", 4.5, "red chip and red button tint"],
  ["--danger-text", "--danger-tint", 4.5, "error message"],
  ["--danger-text", "--surface", 4.5, "red text on a card"],
  ["--warn", "--warn-tint", 4.5, "waiting chip, warning message"],
  ["--warn", "--surface", 4.5, "amber text on a card"],
  ["--on-sun", "--sun", 4.5, "count badge"],
  ["--focus", "--surface", 3, "focus ring"],
];

describe.each(Object.keys(themes) as Array<keyof typeof themes>)("contrast in the %s theme", (name) => {
  const t = themes[name];
  const color = (ref: string) => hex(ref.startsWith("#") ? ref : (t[ref] ?? ""));
  it.each(PAIRS)("%s on %s is at least %s:1 (%s)", (fg, bg, min) => {
    const f = color(fg);
    const b = color(bg);
    expect(f, `${fg} must be a #rrggbb colour`).not.toBeNull();
    expect(b, `${bg} must be a #rrggbb colour`).not.toBeNull();
    expect(contrast(f!, b!)).toBeGreaterThanOrEqual(min);
  });

  it("text on the hero card is readable over the whole gradient", () => {
    const stops = (t["--hero-bg"].match(/#[0-9a-f]{6}/gi) ?? []);
    expect(stops.length).toBeGreaterThanOrEqual(2);
    for (const stop of stops) {
      for (const [token, min] of [["--on-hero", 4.5], ["--on-hero-2", 4.5], ["--hero-accent", 4.5], ["--on-hero-3", 3]] as const) {
        const fg = hex(t[token]);
        expect(fg, token).not.toBeNull();
        expect(contrast(fg!, stop), `${token} on ${stop}`).toBeGreaterThanOrEqual(min);
      }
    }
  });
});
