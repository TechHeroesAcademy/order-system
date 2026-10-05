"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";

export function BarList({
  items,
  colorClassName = "bg-primary",
  max,
  valueSuffix,
}: {
  items: { label: string; value: number }[];
  colorClassName?: string;
  max?: number;
  valueSuffix?: string;
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
            {item.value}
            {valueSuffix}
          </span>
        </div>
      ))}
    </div>
  );
}
