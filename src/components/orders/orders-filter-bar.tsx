"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useState, useTransition } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Search } from "lucide-react";
import { ORDER_STATUS_LABELS_AR } from "@/lib/domain/order-status";
import type { OrderStatus, Region, Profile } from "@/types/database";

const STATUS_OPTIONS: (OrderStatus | "all")[] = [
  "all",
  "new",
  "assigned",
  "collected",
  "at_factory",
  "ready",
  "with_driver",
  "delivered",
  "refused",
  "cancelled",
];

export function OrdersFilterBar({
  regions,
  drivers,
  basePath,
}: {
  regions: Region[];
  drivers: Profile[];
  basePath: string;
}) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [search, setSearch] = useState(searchParams.get("q") ?? "");
  const [, startTransition] = useTransition();

  function updateParam(key: string, value: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (value === "all" || !value) params.delete(key);
    else params.set(key, value);
    params.delete("page");
    startTransition(() => router.push(`${basePath}?${params.toString()}`));
  }

  function submitSearch() {
    updateParam("q", search);
  }

  const [minPieces, setMinPieces] = useState(searchParams.get("minPieces") ?? "");
  const [maxPieces, setMaxPieces] = useState(searchParams.get("maxPieces") ?? "");

  function submitPieces() {
    updateParam("minPieces", minPieces);
    updateParam("maxPieces", maxPieces);
  }

  return (
    <div className="flex flex-wrap gap-2">
      <div className="flex min-w-56 flex-1 gap-2">
        <Input
          placeholder="ابحث برقم الأوردر، اسم العميل، أو الهاتف"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submitSearch()}
        />
        <Button variant="outline" size="icon" onClick={submitSearch}>
          <Search className="size-4" />
        </Button>
      </div>

      <Select defaultValue={searchParams.get("status") ?? "all"} onValueChange={(v) => updateParam("status", v)}>
        <SelectTrigger className="w-40">
          <SelectValue placeholder="الحالة" />
        </SelectTrigger>
        <SelectContent>
          {STATUS_OPTIONS.map((s) => (
            <SelectItem key={s} value={s}>
              {s === "all" ? "كل الحالات" : ORDER_STATUS_LABELS_AR[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select defaultValue={searchParams.get("region") ?? "all"} onValueChange={(v) => updateParam("region", v)}>
        <SelectTrigger className="w-40">
          <SelectValue placeholder="المنطقة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل المناطق</SelectItem>
          {regions.map((r) => (
            <SelectItem key={r.id} value={r.id}>
              {r.name}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select defaultValue={searchParams.get("driver") ?? "all"} onValueChange={(v) => updateParam("driver", v)}>
        <SelectTrigger className="w-40">
          <SelectValue placeholder="المندوب" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل المندوبين</SelectItem>
          {drivers.map((d) => (
            <SelectItem key={d.id} value={d.id}>
              {d.full_name}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <div className="flex items-center gap-1.5">
        <Input
          type="date"
          dir="ltr"
          className="w-40"
          defaultValue={searchParams.get("from") ?? ""}
          onChange={(e) => updateParam("from", e.target.value)}
          aria-label="من تاريخ"
        />
        <span className="text-sm text-muted-foreground">إلى</span>
        <Input
          type="date"
          dir="ltr"
          className="w-40"
          defaultValue={searchParams.get("to") ?? ""}
          onChange={(e) => updateParam("to", e.target.value)}
          aria-label="إلى تاريخ"
        />
      </div>

      <div className="flex items-center gap-1.5">
        <Input
          type="number"
          min={0}
          placeholder="أقل عدد قطع"
          className="w-32"
          value={minPieces}
          onChange={(e) => setMinPieces(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submitPieces()}
          onBlur={submitPieces}
        />
        <Input
          type="number"
          min={0}
          placeholder="أكثر عدد قطع"
          className="w-32"
          value={maxPieces}
          onChange={(e) => setMaxPieces(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submitPieces()}
          onBlur={submitPieces}
        />
      </div>
    </div>
  );
}
