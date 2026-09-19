/* EL REWAD service worker — push notifications only.
 *
 * Deliberately NOT an offline/caching service worker. This app is entirely
 * server-rendered against live order data, and a cache layer here would mean
 * a driver could be shown a stale order status with no indication it was
 * stale — which, in a system where the status decides what the driver does
 * next, is worse than a failed load. The only jobs here are: receive a push,
 * show it, and open the right screen when it is tapped.
 *
 * This file is served from /sw.js at the site root on purpose. A service
 * worker can only control pages at or below its own path, and push
 * subscriptions belong to the registration — served from a subdirectory it
 * could not cover the whole app.
 */

// Take over without waiting for every existing tab to close, so a fixed
// version of this file is live on the next page load rather than whenever
// the user happens to close all their tabs.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  // Everything below has to survive a malformed or empty payload. A push
  // event that throws shows the browser's own generic "site has been
  // updated" notification, which is worse than showing nothing, so the
  // parse is defensive rather than trusting.
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = {};
  }

  const title = payload.title || "EL REWAD";
  const options = {
    body: payload.body || "",
    // The app icon, so the notification is recognisable on the lock screen.
    icon: "/icons/icon-192.png",
    // Android shows this small monochrome mark in the status bar.
    badge: "/icons/icon-192.png",
    lang: "ar",
    dir: "rtl",
    // Grouping key: a second message on the same order replaces the first
    // rather than stacking. A driver returning to their phone after an hour
    // should see one current notification per order, not twelve.
    tag: payload.tag || undefined,
    // ...but still buzz for the replacement, because a new message on an
    // order you already had a notification for is still news.
    renotify: Boolean(payload.tag),
    // Carried through to the click handler below.
    data: { url: payload.url || "/" },
    // Order assignments are the one thing a driver must not miss, so they
    // stay on screen until acknowledged instead of auto-dismissing.
    requireInteraction: Boolean(payload.requireInteraction),
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "/";

  event.waitUntil(
    (async () => {
      const allClients = await self.clients.matchAll({
        type: "window",
        includeUncontrolled: true,
      });

      // Prefer focusing a window the app is already open in and navigating
      // it, rather than opening a second one. Someone tapping three
      // notifications should end up with one app window on the third order,
      // not three windows.
      for (const client of allClients) {
        if ("focus" in client) {
          await client.focus();
          if ("navigate" in client) {
            try {
              await client.navigate(target);
            } catch {
              // navigate() rejects across origins and in a few embedded
              // cases; a focused window on the wrong screen still beats
              // nothing, so this is swallowed rather than escalated.
            }
          }
          return;
        }
      }

      if (self.clients.openWindow) {
        await self.clients.openWindow(target);
      }
    })(),
  );
});
