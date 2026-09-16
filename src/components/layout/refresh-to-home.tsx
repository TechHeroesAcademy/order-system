"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";

/**
 * "When I refresh, always go to the main page" — a deliberate, explicit
 * product choice (not a bug workaround): reloading the browser on ANY page
 * of the app — a dashboard, /login, /track, anywhere — lands back on "/"
 * instead of re-rendering wherever the reload happened.
 *
 * Detecting an actual browser reload (not a normal Next.js client-side
 * navigation) uses the Navigation Timing API: `entries[0].type === "reload"`
 * is only ever true for the document load that resulted from the user
 * hitting refresh (F5 / the reload button) — a Link click, router.push, or
 * router.refresh() (a soft RSC re-fetch, not a new document load) never
 * produces a "reload" entry. This component lives in the root layout, which
 * Next.js mounts exactly once per real document load and never remounts on
 * client-side navigation, so the check below runs precisely once per actual
 * page load/reload — never on in-app navigation between pages.
 */
export function RefreshToHome() {
  const pathname = usePathname();
  const router = useRouter();

  useEffect(() => {
    if (pathname === "/") return;
    try {
      const [entry] = performance.getEntriesByType("navigation") as PerformanceNavigationTiming[];
      if (entry?.type === "reload") {
        router.replace("/");
      }
    } catch {
      // Navigation Timing API unavailable in this browser — not worth
      // failing over, this is a nice-to-have UX behavior, not a guarantee.
    }
    // Intentionally once, right when this document finished loading —
    // pathname/router are read fresh above and don't need to re-trigger this.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return null;
}
