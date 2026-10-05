"use client";

import { useEffect } from "react";
import { usePathname, useRouter } from "next/navigation";

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
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return null;
}
