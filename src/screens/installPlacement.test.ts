import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// Omar's decision (2026-11-08): the "install the app" line is on the login screen only, and never inside the app.
const screensDir = new URL("./", import.meta.url);
const read = (rel: string) => readFileSync(new URL(rel, import.meta.url), "utf8");
const screenFiles = readdirSync(screensDir).filter((f) => /\.tsx?$/.test(f) && !f.endsWith(".test.ts"));
const USES_INSTALL_UI = /\b(InstallLine|useInstall|installStore|installView|installState|createInstallStore|startInstallCapture)\b/;
const ALLOWED = ["Login.tsx", "InstallLine.tsx", "hooks.ts"];

describe("where the install line lives", () => {
  it("no screen inside the app uses it (Home, Main, Profile, Requests, ...)", () => {
    const inside = screenFiles.filter((f) => !ALLOWED.includes(f));
    expect(inside.length).toBeGreaterThan(5);   // the scan really reads the screens
    expect(inside.filter((f) => USES_INSTALL_UI.test(read(f)))).toEqual([]);
    expect(read("../App.tsx")).not.toMatch(USES_INSTALL_UI);
  });

  it("the old button at the foot of Home is gone too", () => {
    expect(read("./Home.tsx")).not.toContain("تثبيت التطبيق");
    expect(read("./Home.tsx")).not.toMatch(/beforeinstallprompt|appinstalled/);
  });

  it("the login screen shows it", () => {
    expect(read("./Login.tsx")).toMatch(/<InstallLine\b/);
    expect(read("./Login.tsx")).toMatch(/useInstall\(\)/);
  });

  it("the browser's prompt is caught at start-up, before any screen (it comes once, early)", () => {
    const main = read("../main.tsx");
    // a real call on its own line: a commented-out call must not pass
    const call = main.match(/^startInstallCapture\(\);/m);
    expect(call).not.toBeNull();
    expect(call!.index!).toBeLessThan(main.indexOf("createRoot("));
  });

  it("no button of the line can submit the login form it sits in", () => {
    const src = read("./InstallLine.tsx");
    const buttons = src.match(/<button\b[^>]*>/g) ?? [];
    expect(buttons.length).toBe(3);
    for (const b of buttons) expect(b).toContain('type="button"');
  });
});
