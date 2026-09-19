/**
 * Browser-side helpers for Web Push. No Firebase: this is the W3C Push API
 * that every supporting browser implements natively. FCM's web SDK is a
 * wrapper around this same API, so going direct reaches exactly the same
 * devices with no SDK download.
 */

export type PushCapability =
  /** Everything is in place; we can ask for permission and subscribe. */
  | "ready"
  /** Already subscribed on this device. */
  | "subscribed"
  /** The person said no. Only they can undo it, in browser settings. */
  | "denied"
  /**
   * iPhone/iPad in a normal Safari tab. Not a browser limitation we can code
   * around: iOS exposes the Push API only to a web app that has been added
   * to the Home Screen, and only on iOS 16.4 or newer.
   */
  | "ios-needs-install"
  /** No Push API at all — an old browser, or a private window. */
  | "unsupported";

/** Running as an installed app rather than in a browser tab. */
export function isStandalone(): boolean {
  if (typeof window === "undefined") return false;
  return (
    window.matchMedia?.("(display-mode: standalone)").matches ||
    // Safari's own, non-standard flag — the only reliable signal on iOS.
    (window.navigator as Navigator & { standalone?: boolean }).standalone === true
  );
}

/**
 * iOS detection has one trap: since iPadOS 13 an iPad reports itself as a
 * Mac, so a user-agent test alone misses every iPad. A Mac with a
 * touchscreen does not exist, so "claims to be a Mac but has touch points"
 * is the standard way to catch it.
 */
export function isIOS(): boolean {
  if (typeof navigator === "undefined") return false;
  const ua = navigator.userAgent;
  if (/iPhone|iPad|iPod/.test(ua)) return true;
  return /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
}

export async function getPushCapability(): Promise<PushCapability> {
  if (typeof window === "undefined") return "unsupported";

  const hasApi = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

  if (!hasApi) {
    // On iOS the Push API is simply absent until the app is installed, so
    // this is the branch an iPhone user in Safari lands in. Telling them
    // "your browser doesn't support notifications" would be both wrong and
    // a dead end, when one step fixes it.
    return isIOS() && !isStandalone() ? "ios-needs-install" : "unsupported";
  }

  if (Notification.permission === "denied") return "denied";

  try {
    const registration = await navigator.serviceWorker.getRegistration();
    const existing = await registration?.pushManager.getSubscription();
    if (existing) return "subscribed";
  } catch {
    // A failed lookup is not proof of anything; fall through and let the
    // subscribe attempt produce a real error if there is one.
  }

  return "ready";
}

/**
 * The VAPID public key travels as base64url text but `applicationServerKey`
 * wants raw bytes. Browsers reject a malformed key with an opaque
 * InvalidAccessError, so the conversion is done explicitly rather than left
 * to chance.
 */
function base64UrlToUint8Array(base64Url: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - (base64Url.length % 4)) % 4);
  const base64 = (base64Url + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = window.atob(base64);
  // Backed by an explicit ArrayBuffer rather than `new Uint8Array(length)`:
  // since TypeScript 5.7 the latter is typed Uint8Array<ArrayBufferLike>,
  // which could be a SharedArrayBuffer, and applicationServerKey only
  // accepts a plain ArrayBuffer view.
  const output = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i);
  return output;
}

function arrayBufferToBase64Url(buffer: ArrayBuffer | null): string {
  if (!buffer) return "";
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export interface PushSubscriptionPayload {
  endpoint: string;
  p256dh: string;
  auth: string;
  userAgent: string;
}

/**
 * Registers the service worker, asks for permission, and subscribes.
 *
 * Must be called from a real click. Browsers reject a permission prompt that
 * wasn't triggered by a user gesture, and Safari is the strictest about it —
 * an `await` of something slow before requestPermission() can be enough to
 * lose the gesture, which is why the registration is awaited first and the
 * prompt comes immediately after.
 */
export async function subscribeToPush(vapidPublicKey: string): Promise<PushSubscriptionPayload> {
  if (!vapidPublicKey) {
    throw new Error("مفتاح الإشعارات غير مضبوط على الخادم");
  }

  const registration = await navigator.serviceWorker.register("/sw.js");
  // A freshly registered worker isn't controlling the page yet; subscribing
  // against a registration that is still installing throws.
  await navigator.serviceWorker.ready;

  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    throw new Error("لم يتم السماح بالإشعارات");
  }

  // Re-use an existing subscription when there is one. Calling subscribe()
  // twice with the same key is allowed, but re-subscribing with a *different*
  // key throws, and reusing keeps one row per device rather than churning.
  const existing = await registration.pushManager.getSubscription();
  const subscription =
    existing ??
    (await registration.pushManager.subscribe({
      // Required to be true by every browser: a push that shows no
      // notification is not permitted on the web.
      userVisibleOnly: true,
      applicationServerKey: base64UrlToUint8Array(vapidPublicKey),
    }));

  return {
    endpoint: subscription.endpoint,
    p256dh: arrayBufferToBase64Url(subscription.getKey("p256dh")),
    auth: arrayBufferToBase64Url(subscription.getKey("auth")),
    userAgent: navigator.userAgent,
  };
}

/** Returns the endpoint that was unsubscribed, or null if there was none. */
export async function unsubscribeFromPush(): Promise<string | null> {
  const registration = await navigator.serviceWorker.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();
  if (!subscription) return null;
  const { endpoint } = subscription;
  await subscription.unsubscribe();
  return endpoint;
}
