/* Waqti: Web Push in the service worker (loaded by the generated sw.js through importScripts).
   Shows the notification sent by the server, and opens/focuses the app when it is tapped. */
self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    data = { title: "وقتي", body: event.data ? event.data.text() : "" };
  }
  const options = {
    body: data.body || "",
    dir: "rtl",
    lang: "ar",
    icon: "icons/icon-192.png",
    badge: "icons/icon-192.png",
    data: { url: data.url || "./" },
  };
  if (data.tag) {
    options.tag = data.tag;
    options.renotify = true;
  }
  event.waitUntil(self.registration.showNotification(data.title || "وقتي", options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || "./", self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of windows) {
      if (w.url.startsWith(self.registration.scope)) {
        await w.focus();
        w.postMessage({ type: "waqti-open", url });
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
