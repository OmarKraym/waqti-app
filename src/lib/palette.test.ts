import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { THEME_COLOR } from "./theme";

// Guards for the design tokens (src/styles/tokens.css): both dark blocks stay identical, every colour token exists in both
// themes, the main colour pairs are readable (WCAG) in light and dark, and the browser-bar colours match the page colour.

const css = readFileSync(new URL("../styles/tokens.css", import.meta.url), "utf8");
const rules = readFileSync(new URL("../styles.css", import.meta.url), "utf8");

function blockAt(start: number): string {
  const open = css.indexOf("{", start);
  let depth = 0;
  for (let i = open; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) return css.slice(open + 1, i);
  }
  throw new Error("unbalanced braces in tokens.css");
}

function tokens(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of body.matchAll(/(--[\w-]+):\s*([^;]+);/g)) out[m[1]] = m[2].trim();
  return out;
}

function find(selector: string, from = 0): number {
  const i = css.indexOf(selector, from);
  if (i < 0) throw new Error(`tokens.css has no "${selector}"`);
  return i;
}

const light = tokens(blockAt(find(":root {")));
const darkChosen = tokens(blockAt(find(':root[data-theme="dark"] {')));
const darkAuto = tokens(blockAt(find(':root:not([data-theme="light"]):not([data-theme="dark"]) {', find("@media (prefers-color-scheme: dark)"))));
const raw = { light, dark: { ...light, ...darkChosen } } as const;

/** A token with every var(--x) replaced by its value in that theme (primitives live in the light block). */
function resolve(theme: Record<string, string>, value: string, depth = 0): string {
  if (depth > 10) throw new Error(`token loop at ${value}`);
  return value.replace(/var\((--[\w-]+)\)/g, (_, name: string) => {
    if (!(name in theme)) throw new Error(`unknown token ${name}`);
    return resolve(theme, theme[name], depth + 1);
  });
}
const themes = {
  light: Object.fromEntries(Object.keys(raw.light).map((k) => [k, resolve(raw.light, raw.light[k])])),
  dark: Object.fromEntries(Object.keys(raw.dark).map((k) => [k, resolve(raw.dark, raw.dark[k])])),
} as const;

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

describe("design tokens", () => {
  it("the two dark blocks are identical", () => {
    expect(Object.keys(darkChosen).length).toBeGreaterThan(30);
    expect(darkAuto).toEqual(darkChosen);
  });

  it("every colour token of the light theme has a dark value (only type, space and shape are shared)", () => {
    // only the theme-dependent tiers must have a dark value: primitives, type, space, shape, layers and motion are shared
    const themed = /^--(color-|shadow-|hero-|punch-|fab-|field-)/;
    const sameInBoth = new Set(["--color-on-accent", "--punch-icon-bg", "--punch-icon-bg-busy", "--shadow-knob"]); // white on a solid fill
    const missing = Object.keys(light).filter((k) => themed.test(k) && !(k in darkChosen) && !sameInBoth.has(k));
    expect(missing).toEqual([]);
    const extra = Object.keys(darkChosen).filter((k) => !(k in light));
    expect(extra).toEqual([]);
  });

  it("no second .switch rule (two of them once broke the notification switches)", () => {
    expect(rules.match(/^\.switch \{/gm)?.length).toBe(1);
  });

  it("the browser-bar colours are the page colour", () => {
    expect(THEME_COLOR.light).toBe(themes.light["--color-bg"]);
    expect(THEME_COLOR.dark).toBe(themes.dark["--color-bg"]);
    const init = readFileSync(new URL("../../public/theme-init.js", import.meta.url), "utf8");
    expect(init).toContain(THEME_COLOR.light);
    expect(init).toContain(THEME_COLOR.dark);
  });
});

/** [foreground token, background token, minimum ratio, what it is]. 4.5 = normal text, 3 = big text and non-text. */
const PAIRS: Array<[string, string, number, string]> = [
  ["--color-text", "--color-bg", 4.5, "body text on the page"],
  ["--color-text", "--color-surface", 4.5, "body text on a card"],
  ["--color-text-muted", "--color-bg", 4.5, "secondary text on the page"],
  ["--color-text-muted", "--color-surface", 4.5, "secondary text on a card"],
  ["--color-text-muted", "--color-surface-sunken", 4.5, "secondary text on a chip"],
  ["--color-border-strong", "--color-surface", 3, "input borders and the switch track (off)"],
  ["--color-success", "--color-surface", 3, "the switch track (on)"],
  ["--color-on-accent", "--color-accent", 4.5, "primary button"],
  ["--color-on-accent", "--color-success", 4.5, "check-in button, send button"],
  ["--color-on-accent", "--punch-out-bg", 4.5, "check-out button"],
  ["--color-on-accent", "--punch-out-bg-hover", 4.5, "check-out button, pressed or hovered"],
  ["--color-on-accent", "--color-danger", 4.5, "delete button"],
  ["--color-on-accent", "--color-disabled", 3, "disabled punch button"],
  ["--color-accent-text", "--color-surface", 4.5, "brand-coloured text on a card"],
  ["--color-accent-text", "--color-accent-tint", 4.5, "brand-coloured text on its tint"],
  ["--color-success-text", "--color-success-tint", 4.5, "green chip, approved"],
  ["--color-success-text", "--color-success-wash", 4.5, "green message"],
  ["--color-success-text", "--color-surface", 4.5, "green text on a card"],
  ["--color-danger-text", "--color-danger-tint", 4.5, "red chip and red button tint"],
  ["--color-danger-text", "--color-danger-tint", 4.5, "error message"],
  ["--color-danger-text", "--color-surface", 4.5, "red text on a card"],
  ["--color-warning-text", "--color-warning-tint", 4.5, "waiting chip, warning message"],
  ["--color-warning-text", "--color-surface", 4.5, "amber text on a card"],
  ["--color-on-warning", "--color-warning", 4.5, "count badge"],
  ["--color-focus", "--color-surface", 3, "focus ring"],
];

describe.each(Object.keys(themes) as Array<keyof typeof themes>)("contrast in the %s theme", (name) => {
  const t = themes[name];
  const color = (ref: string) => hex(t[ref] ?? "");
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
      for (const [token, min] of [["--hero-text", 4.5], ["--hero-text-muted", 4.5], ["--hero-accent", 4.5], ["--hero-text-subtle", 3]] as const) {
        const fg = hex(t[token]);
        expect(fg, token).not.toBeNull();
        expect(contrast(fg!, stop), `${token} on ${stop}`).toBeGreaterThanOrEqual(min);
      }
    }
  });
});
