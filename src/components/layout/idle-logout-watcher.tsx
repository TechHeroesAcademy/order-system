"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { signOutAction } from "@/lib/actions/staff-auth";

const IDLE_LIMIT_MS = 10 * 60 * 1000;
const ACTIVITY_EVENTS = ["mousedown", "mousemove", "keydown", "touchstart", "scroll"] as const;

export function IdleLogoutWatcher() {
  const router = useRouter();
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    function signOutForInactivity() {
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
