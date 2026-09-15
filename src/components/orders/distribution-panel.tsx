"use client";

import { useEffect, useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, Sparkles, UserCheck, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import {
  suggestDriversAction,
  setOrderDistributionAction,
  clearOrderDistributionAction,
  approveDistributionAction,
} from "@/lib/actions/orders";
import type { SuggestedDriverRow } from "@/types/database";
import { cn } from "@/lib/utils";

export function DistributionPanel({
  orderId,
  assignedDriverId,
  assignedDriverName,
  canApprove,
}: {
  orderId: string;
  assignedDriverId: string | null;
  assignedDriverName: string | null;
  canApprove: boolean;
}) {
  const [drivers, setDrivers] = useState<SuggestedDriverRow[] | null>(null);
  const [loadingDrivers, setLoadingDrivers] = useState(true);
  const [pending, startTransition] = useTransition();

  useEffect(() => {
    let active = true;
    suggestDriversAction(orderId).then((res) => {
      if (!active) return;
      setLoadingDrivers(false);
      if (res.ok) setDrivers(res.data);
    });
    return () => {
      active = false;
    };
  }, [orderId]);

  function assign(driverId: string, isSuggestion: boolean) {
    startTransition(async () => {
      const res = await setOrderDistributionAction(orderId, driverId, isSuggestion);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم تحديد المندوب — بانتظار اعتماد Owner");
    });
  }

  function clear() {
    startTransition(async () => {
      const res = await clearOrderDistributionAction(orderId);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم إلغاء التوزيع المقترح");
    });
  }

  function approve() {
    startTransition(async () => {
      const res = await approveDistributionAction(orderId);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم اعتماد التوزيع وإرسال الأوردر للمندوب");
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">توزيع الأوردر على مندوب</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {assignedDriverId && (
          <div className="flex items-center justify-between rounded-lg border bg-accent/50 p-3">
            <div className="flex items-center gap-2">
              <UserCheck className="size-4 text-amber-700 dark:text-amber-400" />
              <span className="text-sm font-medium">{assignedDriverName}</span>
              <Badge variant="warning">بانتظار الاعتماد</Badge>
            </div>
            <div className="flex gap-2">
              {canApprove && (
                <Button size="sm" onClick={approve} disabled={pending}>
                  {pending && <Loader2 className="animate-spin" />}
                  اعتماد التوزيع
                </Button>
              )}
              <Button size="sm" variant="ghost" onClick={clear} disabled={pending}>
                <X className="size-4" />
              </Button>
            </div>
          </div>
        )}

        {!assignedDriverId && (
          <>
            {loadingDrivers && <p className="text-sm text-muted-foreground">جاري تحميل المندوبين...</p>}
            {drivers && drivers.length === 0 && (
              <p className="text-sm text-muted-foreground">لا يوجد مندوبون نشطون حاليًا.</p>
            )}
            <ul className="space-y-2">
              {drivers?.map((d, idx) => (
                <li
                  key={d.driver_id}
                  className={cn(
                    "flex items-center justify-between rounded-lg border p-3",
                    idx === 0 && "border-primary/50 bg-primary/5",
                  )}
                >
                  <div>
                    <p className="flex items-center gap-1.5 text-sm font-medium">
                      {d.full_name}
                      {idx === 0 && (
                        <span className="inline-flex items-center gap-0.5 text-xs text-amber-700 dark:text-amber-400">
                          <Sparkles className="size-3" /> مقترح
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {d.covers_region ? "يغطي المنطقة" : "لا يغطي المنطقة"} · {d.active_orders_count} أوردر حالي
                    </p>
                  </div>
                  <Button size="sm" variant="outline" onClick={() => assign(d.driver_id, idx === 0)} disabled={pending}>
                    {pending && <Loader2 className="animate-spin" />}
                    تعيين
                  </Button>
                </li>
              ))}
            </ul>
          </>
        )}
      </CardContent>
    </Card>
  );
}
