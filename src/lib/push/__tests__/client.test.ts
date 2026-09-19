import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { getPushCapability, isIOS, isStandalone } from "../client";

/**
 * Device detection is the part of this feature most likely to mislead
 * someone: get it wrong and an iPhone user is told their browser doesn't
 * support notifications (a dead end) instead of being shown the one step
 * that fixes it, or an Android user is shown iPhone install instructions
 * they cannot follow.
 */

const REAL_UA = navigator.userAgent;

function setUserAgent(ua: string) {
  Object.defineProperty(navigator, "userAgent", { value: ua, configurable: true });
}
function setTouchPoints(n: number) {
  Object.defineProperty(navigator, "maxTouchPoints", { value: n, configurable: true });
}
function setStandalone(value: boolean) {
  window.matchMedia = vi.fn().mockReturnValue({ matches: value }) as unknown as typeof window.matchMedia;
}

/** jsdom has no Push API, which is exactly the shape of iOS Safari. */
function removePushApi() {
  Reflect.deleteProperty(window, "PushManager");
  Reflect.deleteProperty(window, "Notification");
}

function installPushApi(permission: NotificationPermission, existingSubscription: unknown = null) {
  Object.defineProperty(window, "PushManager", { value: class {}, configurable: true });
  Object.defineProperty(window, "Notification", {
    value: { permission, requestPermission: vi.fn() },
    configurable: true,
  });
  Object.defineProperty(navigator, "serviceWorker", {
    value: {
      getRegistration: vi.fn().mockResolvedValue({
        pushManager: { getSubscription: vi.fn().mockResolvedValue(existingSubscription) },
      }),
    },
    configurable: true,
  });
}

const IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15";
const IPAD_AS_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15";
const ANDROID = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120";
const DESKTOP_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120";

beforeEach(() => {
  setTouchPoints(0);
  setStandalone(false);
});
afterEach(() => {
  setUserAgent(REAL_UA);
  vi.restoreAllMocks();
});

describe("isIOS", () => {
  it("recognises an iPhone", () => {
    setUserAgent(IPHONE);
    expect(isIOS()).toBe(true);
  });

  it("recognises an iPad, which reports itself as a Mac", () => {
    // The trap: since iPadOS 13 the user agent is indistinguishable from a
    // desktop Mac. Touch points are what tell them apart.
    setUserAgent(IPAD_AS_MAC);
    setTouchPoints(5);
    expect(isIOS()).toBe(true);
  });

  it("does not mistake a real Mac for an iPad", () => {
    setUserAgent(DESKTOP_MAC);
    setTouchPoints(0);
    expect(isIOS()).toBe(false);
  });

  it("does not mistake Android for iOS", () => {
    setUserAgent(ANDROID);
    setTouchPoints(5);
    expect(isIOS()).toBe(false);
  });
});

describe("isStandalone", () => {
  it("is true when launched from the Home Screen", () => {
    setStandalone(true);
    expect(isStandalone()).toBe(true);
  });

  it("is true on iOS via Safari's own non-standard flag", () => {
    setStandalone(false);
    Object.defineProperty(navigator, "standalone", { value: true, configurable: true });
    expect(isStandalone()).toBe(true);
    Reflect.deleteProperty(navigator, "standalone");
  });
});

describe("getPushCapability", () => {
  it("tells an iPhone in Safari to install, not that it is unsupported", async () => {
    setUserAgent(IPHONE);
    removePushApi();
    expect(await getPushCapability()).toBe("ios-needs-install");
  });

  it("reports plainly unsupported on a browser with no Push API and no install path", async () => {
    setUserAgent(ANDROID);
    removePushApi();
    expect(await getPushCapability()).toBe("unsupported");
  });

  it("is ready on Android with the API present and permission not yet asked", async () => {
    setUserAgent(ANDROID);
    installPushApi("default");
    expect(await getPushCapability()).toBe("ready");
  });

  it("reports denied rather than offering a button that cannot work", async () => {
    setUserAgent(ANDROID);
    installPushApi("denied");
    expect(await getPushCapability()).toBe("denied");
  });

  it("reports an existing subscription as already subscribed", async () => {
    setUserAgent(ANDROID);
    installPushApi("granted", { endpoint: "https://push.test/x" });
    expect(await getPushCapability()).toBe("subscribed");
  });

  it("falls back to ready when the subscription lookup throws", async () => {
    setUserAgent(ANDROID);
    installPushApi("granted");
    Object.defineProperty(navigator, "serviceWorker", {
      value: { getRegistration: vi.fn().mockRejectedValue(new Error("nope")) },
      configurable: true,
    });
    // A failed lookup is not proof of anything — offering the button lets
    // the real subscribe attempt surface a real error.
    expect(await getPushCapability()).toBe("ready");
  });
});
