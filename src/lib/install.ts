// The "install the app" line on the login screen (the only place that offers it; it is not inside the app).
// Android / desktop Chrome: the browser offers installing with a `beforeinstallprompt` event; it comes once, early (often before
// the login screen is on the screen), so it is captured here at start-up and kept until the employee taps the button.
// iPhone / iPad: there is no such event, so the line only shows the instruction the app already uses elsewhere.
// Nothing here ever throws: storage can be blocked (private mode), and the app must work without it.
import { isIosDevice, isStandalone } from "./push";

export type InstallState = "hidden" | "prompt" | "ios";

export interface InstallEnv {
  /** Opened from the home-screen icon (the installed app). */
  standalone: boolean;
  isIos: boolean;
  /** The browser's install prompt was captured and not used yet. */
  hasPrompt: boolean;
  /** The browser said `appinstalled` during this page's life. */
  installed: boolean;
}

/** Pure decision (unit-tested). Never a dead button: with no prompt and no iOS instruction there is nothing to show. */
export function installState(e: InstallEnv): InstallState {
  if (e.standalone || e.installed) return "hidden";
  if (e.isIos) return "ios";
  return e.hasPrompt ? "prompt" : "hidden";
}

/** The words the app already uses for iPhone (the same sentence ends the "install first" screen). */
export const IOS_INSTALL_TEXT = "اضغط زر المشاركة في Safari ثم «إضافة إلى الشاشة الرئيسية»، وافتح وقتي من الأيقونة.";

export interface InstallSnapshot {
  hasPrompt: boolean;
  installed: boolean;
  /** The employee closed the line or declined the browser's dialog: it stays hidden for this session. */
  dismissed: boolean;
}

/** What the screen shows for a store snapshot in this browser. */
export function installView(s: InstallSnapshot, env: { standalone: boolean; isIos: boolean }): InstallState {
  if (s.dismissed) return "hidden";
  return installState({ ...env, hasPrompt: s.hasPrompt, installed: s.installed });
}

/** The browser's install event. `prompt()` shows its own dialog, once. */
interface PromptEvent extends Event {
  prompt(): Promise<void>;
  userChoice?: Promise<{ outcome: string }>;
}

type Store = Pick<Storage, "getItem" | "setItem">;
const DISMISSED_KEY = "waqti-install-dismissed";

function sessionStore(): Store | null {
  try {
    return globalThis.sessionStorage ?? null;
  } catch {
    return null;
  }
}

export interface InstallStore {
  /** The same object until something changes (React compares by identity). */
  snapshot(): InstallSnapshot;
  subscribe(fn: () => void): () => void;
  /** Starts listening for `beforeinstallprompt` and `appinstalled`; returns the function that stops. */
  attach(target: EventTarget): () => void;
  /** Shows the browser's install dialog. A declined or failed dialog hides the line for the session. */
  prompt(): Promise<"accepted" | "dismissed" | "unavailable">;
  /** The close button. */
  dismiss(): void;
}

export function createInstallStore(storage: Store | null = sessionStore()): InstallStore {
  let pending: PromptEvent | null = null;
  let installed = false;
  let dismissed = false;
  try {
    dismissed = storage?.getItem(DISMISSED_KEY) === "1";
  } catch {
    dismissed = false;
  }
  let snap: InstallSnapshot = { hasPrompt: false, installed, dismissed };
  const listeners = new Set<() => void>();

  function publish(): void {
    const next = { hasPrompt: pending !== null, installed, dismissed };
    if (next.hasPrompt === snap.hasPrompt && next.installed === snap.installed && next.dismissed === snap.dismissed) return;
    snap = next;
    listeners.forEach((fn) => fn());
  }

  function dismiss(): void {
    dismissed = true;
    try {
      storage?.setItem(DISMISSED_KEY, "1");
    } catch {
      /* private mode: it lasts until the page is closed */
    }
    publish();
  }

  return {
    snapshot: () => snap,
    subscribe(fn) {
      listeners.add(fn);
      return () => { listeners.delete(fn); };
    },
    attach(target) {
      const onPrompt = (e: Event) => {
        e.preventDefault();   // no browser mini-bar: the line on the login screen is the one place that offers it
        pending = e as PromptEvent;
        publish();
      };
      const onInstalled = () => {
        pending = null;
        installed = true;
        publish();
      };
      target.addEventListener("beforeinstallprompt", onPrompt);
      target.addEventListener("appinstalled", onInstalled);
      return () => {
        target.removeEventListener("beforeinstallprompt", onPrompt);
        target.removeEventListener("appinstalled", onInstalled);
      };
    },
    async prompt() {
      const ev = pending;
      if (!ev) return "unavailable";
      pending = null;   // a prompt can be shown once
      publish();
      let outcome: "accepted" | "dismissed" = "dismissed";
      try {
        await ev.prompt();
        outcome = (await ev.userChoice)?.outcome === "accepted" ? "accepted" : "dismissed";
      } catch {
        outcome = "dismissed";
      }
      if (outcome === "dismissed") dismiss();
      return outcome;
    },
    dismiss,
  };
}

/** The store of this page. */
export const installStore = createInstallStore();

/** Called once at start-up (before the first screen), so the browser's event is not missed while Login is showing. */
export function startInstallCapture(): () => void {
  return installStore.attach(window);
}

/** What this browser is: used with `installView`. */
export function readInstallEnv(): { standalone: boolean; isIos: boolean } {
  return { standalone: isStandalone(), isIos: isIosDevice() };
}
