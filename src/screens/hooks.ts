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
