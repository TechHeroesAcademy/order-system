"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";

/**
 * A horizontal bar-list chart (magnitude by category — spec section 23's
 * "أكثر المناطق طلبًا" / "أداء المندوبين"). Client component so the bars can
 * animate in from 0 on mount instead of snapping straight to their final
 * width, matching the rest of this page's motion.
 *
 * Single hue by design (sequential/magnitude job, not identity) — see the
 * dataviz skill's color-formula: one series, one color, never a rainbow.
 */
export function BarList({
  items,
  colorClassName = "bg-primary",
  max,
  formatValue,
}: {
  items: { label: string; value: number }[];
  colorClassName?: string;
  /** Fixed max (e.g. 100 for a percentage scale) instead of the tallest bar. */
  max?: number;
  formatValue?: (value: number) => string;
}) {
  const [animated, setAnimated] = useState(false);
  useEffect(() => {
    const frame = requestAnimationFrame(() => setAnimated(true));
    return () => cancelAnimationFrame(frame);
  }, []);

  const scale = max ?? Math.max(1, ...items.map((i) => i.value));

  if (items.length === 0) return null;

  return (
    <div className="space-y-2.5">
      {items.map((item, idx) => (
        <div key={item.label} className="flex items-center gap-3">
          <span className="w-32 shrink-0 truncate text-sm">{item.label}</span>
          <div className="h-2 flex-1 overflow-hidden rounded-full bg-muted">
            <div
              className={cn("h-full rounded-full transition-[width] duration-700 ease-out", colorClassName)}
              style={{
                width: animated ? `${Math.min(100, (item.value / scale) * 100)}%` : "0%",
                transitionDelay: `${idx * 60}ms`,
              }}
            />
          </div>
          <span className="w-12 shrink-0 text-end text-sm tabular-nums text-muted-foreground">
            {formatValue ? formatValue(item.value) : item.value}
          </span>
        </div>
      ))}
    </div>
  );
}
