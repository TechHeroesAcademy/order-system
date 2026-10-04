"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { signOutAction } from "@/lib/actions/staff-auth";

const IDLE_LIMIT_MS = 10 * 60 * 1000;
const ACTIVITY_EVENTS = ["mousedown", "mousemove", "keydown", "touchstart", "scroll"] as const;

/**
 * Signs the user out after 10 minutes with no mouse/keyboard/touch/scroll
 * activity anywhere on the page. Mounted once in <AppShell>, so it covers
 * every authenticated area (Owner/Moderator/Driver/Factory) uniformly.
 */
export function IdleLogoutWatcher() {
  const router = useRouter();
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    function signOutForInactivity() {
      // The cookie is httpOnly, so clearing it has to happen on the server.
      // The redirect runs either way: if the call fails, the person must
      // still end up off the page they walked away from, and the proxy will
      // turn them back at the door.
      signOutAction().finally(() => {
        router.replace("/login");
        router.refresh();
      });
    }

    function resetTimer() {
      if (timerRef.current) clearTimeout(timerRef.current);
      timerRef.current = setTimeout(signOutForInactivity, IDLE_LIMIT_MS);
    }

    resetTimer();
    ACTIVITY_EVENTS.forEach((event) => window.addEventListener(event, resetTimer, { passive: true }));

    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
      ACTIVITY_EVENTS.forEach((event) => window.removeEventListener(event, resetTimer));
    };
  }, [router]);

  return null;
}
