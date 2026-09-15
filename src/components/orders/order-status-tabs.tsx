"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useTransition } from "react";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";

/**
 * Quick-access shortcuts on top of the full status dropdown in
 * OrdersFilterBar: "الكل" always includes every status (delivered and
 * cancelled included — nothing is hidden by default), plus one-click jumps
 * to "تم التسليم" (Done) and "الملغاة" (Cancelled), which the fine-grained
 * status dropdown already supported but buried behind a menu.
 */
const QUICK_TABS: { value: "all" | "delivered" | "cancelled"; label: string }[] = [
  { value: "all", label: "الكل" },
  { value: "delivered", label: "تم التسليم" },
  { value: "cancelled", label: "الملغاة" },
];

export function OrderStatusTabs({ basePath }: { basePath: string }) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();
  const currentStatus = searchParams.get("status") ?? "all";
  // Any status not covered by a quick tab (new/assigned/collected/...) still
  // came from the detailed dropdown — keep that tab visually active instead
  // of silently jumping back to "all".
  const activeValue = QUICK_TABS.some((t) => t.value === currentStatus) ? currentStatus : "other";

  function goTo(status: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (status === "all") params.delete("status");
    else params.set("status", status);
    params.delete("page");
    startTransition(() => router.push(`${basePath}?${params.toString()}`));
  }

  return (
    <Tabs value={activeValue} onValueChange={goTo}>
      <TabsList>
        {QUICK_TABS.map((t) => (
          <TabsTrigger key={t.value} value={t.value}>
            {t.label}
          </TabsTrigger>
        ))}
        {activeValue === "other" && (
          <TabsTrigger value="other" className={cn("data-[state=active]:bg-background")}>
            حالة أخرى
          </TabsTrigger>
        )}
      </TabsList>
    </Tabs>
  );
}
