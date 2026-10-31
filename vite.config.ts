/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

// The service worker caches ONLY the app shell (HTML/JS/CSS/fonts/icons) so the
// app opens fast and can be installed. It never caches or queues Supabase calls:
// attendance always needs a live server answer (offline attendance is not approved).
// BASE_PATH=/waqti-app/ for GitHub Pages; "/" for a root domain.
const base = process.env.BASE_PATH ?? "/";

export default defineConfig({
  base,
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      includeAssets: ["icons/icon.svg", "icons/apple-touch-icon.png", "push-sw.js"],
      manifest: {
        name: "وقتي - الحضور والانصراف",
        short_name: "وقتي",
        description: "تسجيل الحضور والانصراف للموظفين",
        lang: "ar",
        dir: "rtl",
        start_url: base,
        scope: base,
        display: "standalone",
        orientation: "portrait",
        background_color: "#F8FAFB",
        theme_color: "#004357",
        icons: [
          { src: "icons/icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "icons/icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "icons/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        globPatterns: ["**/*.{js,css,html,svg,png,woff2}"],
        navigateFallback: `${base}index.html`,
        // No runtimeCaching on purpose: API requests always go to the network.
        runtimeCaching: [],
        cleanupOutdatedCaches: true,
        // Web Push handlers (public/push-sw.js): show notifications, open the app when tapped.
        importScripts: ["push-sw.js"],
      },
    }),
  ],
  test: {
    environment: "node",
  },
});
