import { describe, expect, it, vi } from "vitest";
import { createInstallStore, installState, installView, IOS_INSTALL_TEXT } from "./install";

const env = { standalone: false, isIos: false, hasPrompt: false, installed: false };

describe("the install button: when it shows", () => {
  it("the installed app never shows it", () => {
    expect(installState({ ...env, standalone: true })).toBe("hidden");
    expect(installState({ ...env, standalone: true, hasPrompt: true })).toBe("hidden");
    expect(installState({ ...env, standalone: true, isIos: true })).toBe("hidden");
  });

  it("Android / desktop Chrome with a captured prompt: the install button", () => {
    expect(installState({ ...env, hasPrompt: true })).toBe("prompt");
  });

  it("iPhone / iPad in Safari: the instruction (there is no prompt on iOS)", () => {
    expect(installState({ ...env, isIos: true })).toBe("ios");
    expect(installState({ ...env, isIos: true, hasPrompt: true })).toBe("ios");
  });

  it("no prompt and not iOS: nothing (never a dead button)", () => {
    expect(installState(env)).toBe("hidden");
  });

  it("after the app was installed: nothing", () => {
    expect(installState({ ...env, hasPrompt: true, installed: true })).toBe("hidden");
    expect(installState({ ...env, isIos: true, installed: true })).toBe("hidden");
  });

  it("the instruction uses the wording the app already has: Share, then Add to Home Screen", () => {
    expect(IOS_INSTALL_TEXT).toContain("زر المشاركة");
    expect(IOS_INSTALL_TEXT).toContain("«إضافة إلى الشاشة الرئيسية»");
    expect(IOS_INSTALL_TEXT).toContain("Safari");
  });
});

/** A browser's `beforeinstallprompt`: it can be cancelled, and prompt() shows the browser's own dialog. */
function promptEvent(outcome: "accepted" | "dismissed" = "accepted") {
  const ev = new Event("beforeinstallprompt", { cancelable: true }) as Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };
  ev.prompt = vi.fn(async () => {});
  ev.userChoice = Promise.resolve({ outcome });
  return ev;
}
function memory(): Pick<Storage, "getItem" | "setItem"> & { data: Record<string, string> } {
  const data: Record<string, string> = {};
  return { data, getItem: (k) => data[k] ?? null, setItem: (k, v) => { data[k] = v; } };
}

describe("the install store", () => {
  it("keeps the browser's prompt (and stops the browser's own mini-bar) when it comes", () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    expect(store.snapshot().hasPrompt).toBe(false);
    const ev = promptEvent();
    target.dispatchEvent(ev);
    expect(ev.defaultPrevented).toBe(true);
    expect(store.snapshot().hasPrompt).toBe(true);
  });

  it("tells the screen when something changed, and only then", () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    const seen = vi.fn();
    store.subscribe(seen);
    target.dispatchEvent(promptEvent());
    expect(seen).toHaveBeenCalledTimes(1);
    const before = store.snapshot();
    expect(store.snapshot()).toBe(before);   // the same object until something changes (React compares by identity)
    store.dismiss();
    expect(seen).toHaveBeenCalledTimes(2);
    expect(store.snapshot()).not.toBe(before);
  });

  it("a subscription can be cancelled", () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    const seen = vi.fn();
    const off = store.subscribe(seen);
    off();
    target.dispatchEvent(promptEvent());
    expect(seen).not.toHaveBeenCalled();
  });

  it("after appinstalled there is no prompt and the app counts as installed", () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    target.dispatchEvent(promptEvent());
    target.dispatchEvent(new Event("appinstalled"));
    expect(store.snapshot()).toMatchObject({ hasPrompt: false, installed: true });
    expect(installView(store.snapshot(), { standalone: false, isIos: false })).toBe("hidden");
  });

  it("a newer prompt replaces the older one", async () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    const first = promptEvent();
    const second = promptEvent();
    target.dispatchEvent(first);
    target.dispatchEvent(second);
    await store.prompt();
    expect(second.prompt).toHaveBeenCalledTimes(1);
    expect(first.prompt).not.toHaveBeenCalled();
  });

  it("the listeners are removed when the wiring is undone", () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    const off = store.attach(target);
    off();
    target.dispatchEvent(promptEvent());
    expect(store.snapshot().hasPrompt).toBe(false);
  });

  it("prompt(): shows the browser's dialog; accepted -> 'accepted', and the used prompt is gone (it works once)", async () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    const ev = promptEvent("accepted");
    target.dispatchEvent(ev);
    expect(await store.prompt()).toBe("accepted");
    expect(ev.prompt).toHaveBeenCalledTimes(1);
    expect(store.snapshot()).toMatchObject({ hasPrompt: false, dismissed: false });
    expect(await store.prompt()).toBe("unavailable");
    expect(ev.prompt).toHaveBeenCalledTimes(1);
  });

  it("prompt(): declining the browser's dialog hides the button for the session", async () => {
    const storage = memory();
    const store = createInstallStore(storage);
    const target = new EventTarget();
    store.attach(target);
    target.dispatchEvent(promptEvent("dismissed"));
    expect(await store.prompt()).toBe("dismissed");
    expect(store.snapshot()).toMatchObject({ hasPrompt: false, dismissed: true });
    // the browser gives a new prompt later in the same session: the button stays hidden
    target.dispatchEvent(promptEvent());
    expect(installView(store.snapshot(), { standalone: false, isIos: false })).toBe("hidden");
    // and a reload of the page in the same session starts hidden too
    const reloaded = createInstallStore(storage);
    expect(reloaded.snapshot().dismissed).toBe(true);
    // a new session (nothing saved) starts with the button
    expect(createInstallStore(memory()).snapshot().dismissed).toBe(false);
  });

  it("prompt(): a dialog that fails counts as declined, never as an error on the screen", async () => {
    const store = createInstallStore(memory());
    const target = new EventTarget();
    store.attach(target);
    const ev = promptEvent();
    ev.prompt = vi.fn(async () => { throw new Error("InvalidStateError"); });
    target.dispatchEvent(ev);
    expect(await store.prompt()).toBe("dismissed");
    expect(store.snapshot().dismissed).toBe(true);
  });

  it("prompt() without a captured prompt does nothing", async () => {
    const store = createInstallStore(memory());
    expect(await store.prompt()).toBe("unavailable");
    expect(store.snapshot().dismissed).toBe(false);
  });

  it("the close button hides it for the session, on iOS too", () => {
    const storage = memory();
    const store = createInstallStore(storage);
    expect(installView(store.snapshot(), { standalone: false, isIos: true })).toBe("ios");
    store.dismiss();
    expect(installView(store.snapshot(), { standalone: false, isIos: true })).toBe("hidden");
    expect(createInstallStore(storage).snapshot().dismissed).toBe(true);
  });

  it("works with no storage at all (private mode): the choice lasts until the page is closed", () => {
    const broken: Pick<Storage, "getItem" | "setItem"> = {
      getItem: () => { throw new Error("blocked"); },
      setItem: () => { throw new Error("blocked"); },
    };
    for (const storage of [broken, null]) {
      const store = createInstallStore(storage);
      expect(store.snapshot().dismissed).toBe(false);
      expect(() => store.dismiss()).not.toThrow();
      expect(store.snapshot().dismissed).toBe(true);
    }
  });

  it("installView: the prompt shows only while it is available, not dismissed, not installed", () => {
    const base = { hasPrompt: true, installed: false, dismissed: false };
    expect(installView(base, { standalone: false, isIos: false })).toBe("prompt");
    expect(installView({ ...base, dismissed: true }, { standalone: false, isIos: false })).toBe("hidden");
    expect(installView({ ...base, installed: true }, { standalone: false, isIos: false })).toBe("hidden");
    expect(installView(base, { standalone: true, isIos: false })).toBe("hidden");
    expect(installView({ ...base, hasPrompt: false }, { standalone: false, isIos: false })).toBe("hidden");
  });
});
