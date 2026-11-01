/// <reference types="vitest/config" />
import { defineConfig, loadEnv, type Plugin } from "vite";
import { configDefaults } from "vitest/config";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

// The service worker caches ONLY the app shell (HTML/JS/CSS/fonts/icons) so the
// app opens fast and can be installed. It never caches or queues Supabase calls:
// attendance always needs a live server answer (offline attendance is not approved).
// BASE_PATH=/waqti-app/ for GitHub Pages; "/" for a root domain.
const base = process.env.BASE_PATH ?? "/";

/** Content-Security-Policy for the built app (security audit SEC-010). GitHub Pages cannot send headers, so it is a
 *  <meta> tag. Only this site and the Supabase project may be reached; no inline or third-party scripts. Not added in
 *  dev, where Vite needs its own websocket. */
function contentSecurityPolicy(supabaseUrl: string | undefined): Plugin {
  const api = supabaseUrl ? new URL(supabaseUrl).origin : "";
  const policy = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    `connect-src 'self'${api ? ` ${api}` : ""}`,
    "manifest-src 'self'",
    "worker-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join("; ");
  return {
    name: "waqti-csp",
    apply: "build",
    transformIndexHtml: () => [{ tag: "meta", attrs: { "http-equiv": "Content-Security-Policy", content: policy }, injectTo: "head-prepend" }],
  };
}

export default defineConfig(({ mode }) => ({
  base,
  plugins: [
    react(),
    contentSecurityPolicy(loadEnv(mode, process.cwd(), "VITE_").VITE_SUPABASE_URL),
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
        background_color: "#F0F3F4",
        theme_color: "#F0F3F4",
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
    // Edge Function tests run in their own Node harness (supabase/functions/*/test.sh).
    exclude: [...configDefaults.exclude, "supabase/**"],
  },
}));
