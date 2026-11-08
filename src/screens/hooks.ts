import { useEffect, useState, useSyncExternalStore } from "react";
import { installStore, installView, readInstallEnv, type InstallState } from "../lib/install";

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

/** The install line of the login screen: what to show, and the two buttons. The browser's event is captured at start-up (see install.ts). */
export function useInstall(): { view: InstallState; install: () => void; close: () => void } {
  const snap = useSyncExternalStore(installStore.subscribe, installStore.snapshot);
  return {
    view: installView(snap, readInstallEnv()),
    install: () => { void installStore.prompt(); },
    close: () => installStore.dismiss(),
  };
}
