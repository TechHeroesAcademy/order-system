"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";

/**
 * A single-metric radial gauge (0-100%) — spec section 23's "نسبة الأوردرات
 * المكتملة" / "معدل التأخير". Client component so the ring animates in from
 * 0 on mount, same motion language as BarList.
 */
export function RadialStat({
  label,
  percent,
  colorClassName = "text-primary",
}: {
  label: string;
  percent: number;
  colorClassName?: string;
}) {
  const [animated, setAnimated] = useState(0);
  const clamped = Math.max(0, Math.min(100, percent));

  useEffect(() => {
    const frame = requestAnimationFrame(() => setAnimated(clamped));
    return () => cancelAnimationFrame(frame);
  }, [clamped]);

  const r = 40;
  const c = 2 * Math.PI * r;
  const offset = c - (animated / 100) * c;

  return (
    <div className="flex flex-col items-center gap-1.5">
      <div className="relative size-24">
        <svg viewBox="0 0 100 100" className="size-24 -rotate-90">
          <circle cx="50" cy="50" r={r} fill="none" strokeWidth="8" className="stroke-muted" />
          <circle
            cx="50"
            cy="50"
            r={r}
            fill="none"
            strokeWidth="8"
            strokeLinecap="round"
            strokeDasharray={c}
            strokeDashoffset={offset}
            className={cn(colorClassName, "stroke-current transition-[stroke-dashoffset] duration-700 ease-out")}
          />
        </svg>
        <div className="absolute inset-0 flex items-center justify-center text-lg font-bold tabular-nums">
          {Math.round(clamped)}%
        </div>
      </div>
      <span className="text-center text-xs text-muted-foreground">{label}</span>
    </div>
  );
}
