"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { signOutAction } from "@/lib/actions/staff-auth";
import { SESSION_IDLE_SECONDS } from "@/lib/auth/session";

// Taken from the server's own number rather than restated. These were 10 and
// 15 minutes, so the browser signed people out five minutes before their
// session was actually due to expire, and the export that exists to keep them
// in step had no consumer.
const IDLE_LIMIT_MS = SESSION_IDLE_SECONDS * 1000;
const ACTIVITY_EVENTS = ["mousedown", "mousemove", "keydown", "touchstart", "scroll"] as const;

export function IdleLogoutWatcher() {
  const router = useRouter();
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    function signOutForInactivity() {
      signOutAction()
        .catch(() => {})
        .finally(() => {
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
