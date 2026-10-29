import { useEffect, useState } from "react";

export function useOnline(): boolean {
  const [online, setOnline] = useState(() => navigator.onLine);
  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    return () => {
      window.removeEventListener("online", up);
      window.removeEventListener("offline", down);
    };
  }, []);
  return online;
}

interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>;
}

/** Returns a function that shows the browser's install dialog, or null when install is not offered. */
export function useInstallPrompt(): (() => void) | null {
  const [event, setEvent] = useState<BeforeInstallPromptEvent | null>(null);
  useEffect(() => {
    const onPrompt = (e: Event) => {
      e.preventDefault();
      setEvent(e as BeforeInstallPromptEvent);
    };
    const onInstalled = () => setEvent(null);
    window.addEventListener("beforeinstallprompt", onPrompt);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onPrompt);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);
  if (!event) return null;
  return () => {
    event.prompt().finally(() => setEvent(null));
  };
}

const IOS_HINT_KEY = "waqti-ios-install-hint-dismissed";

/** iPhone/iPad Safari has no install prompt: show a one-line "Add to Home Screen" hint instead. */
export function useIosInstallHint(): [boolean, () => void] {
  const [show, setShow] = useState(() => {
    const ua = navigator.userAgent;
    const isIos = /iPad|iPhone|iPod/.test(ua) || (ua.includes("Macintosh") && navigator.maxTouchPoints > 1);
    const standalone =
      window.matchMedia?.("(display-mode: standalone)").matches ||
      (navigator as Navigator & { standalone?: boolean }).standalone === true;
    let dismissed = false;
    try {
      dismissed = localStorage.getItem(IOS_HINT_KEY) === "1";
    } catch {
      /* storage blocked: just show it */
    }
    return isIos && !standalone && !dismissed;
  });
  const dismiss = () => {
    setShow(false);
    try {
      localStorage.setItem(IOS_HINT_KEY, "1");
    } catch {
      /* ignore */
    }
  };
  return [show, dismiss];
}
