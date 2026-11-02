import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { registerSW } from "virtual:pwa-register";
import "@fontsource/ibm-plex-sans-arabic/400.css";
import "@fontsource/ibm-plex-sans-arabic/500.css";
import "@fontsource/ibm-plex-sans-arabic/600.css";
import "@fontsource/ibm-plex-sans-arabic/700.css";
import "@fontsource/readex-pro/arabic-500.css";
import "@fontsource/readex-pro/arabic-700.css";
import "@fontsource/readex-pro/latin-500.css";
import "@fontsource/readex-pro/latin-700.css";
import "./styles.css";
import { keepStorage } from "./lib/localSettings";
import { initTheme } from "./lib/theme";
import { App } from "./App";

// Saved light/dark choice (public/theme-init.js already applied it before the first paint; this also follows the phone in "auto").
initTheme();

// Ask the browser to keep this phone's saved settings (theme, reminders) even when space runs low.
void keepStorage();

// App shell only (see vite.config.ts). Updates install themselves on the next open.
registerSW({ immediate: true });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
