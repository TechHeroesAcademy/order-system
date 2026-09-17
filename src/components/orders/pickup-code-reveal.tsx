"use client";

import { useState } from "react";
import { Eye, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { getOrderPickupCodeAction } from "@/lib/actions/orders";

/**
 * Same click-to-reveal pattern as <DeliveryCodeReveal>, for the pickup
 * code instead — the code the driver needs from the customer to confirm
 * they collected the order (migration 0024). Owner/Moderator can look it
 * up again on demand (e.g. the customer needs it re-read to them) via a
 * dedicated RPC that keeps it out of reach of drivers, same reasoning as
 * the delivery code: seeing it in advance would let a driver "confirm
 * pickup" without ever actually visiting the customer.
 */
export function PickupCodeReveal({ orderId }: { orderId: string }) {
  const [state, setState] = useState<"hidden" | "loading" | "shown" | "unavailable">("hidden");
  const [code, setCode] = useState<string | null>(null);

  async function reveal() {
    setState("loading");
    const res = await getOrderPickupCodeAction(orderId);
    if (!res.ok) {
      toast.error(res.error);
      setState("hidden");
      return;
    }
    if (!res.data.code) {
      setState("unavailable");
      return;
    }
    setCode(res.data.code);
    setState("shown");
  }

  if (state === "shown" && code) {
    return (
      <div className="rounded-lg border bg-muted/40 p-3 text-center">
        <p className="text-xs text-muted-foreground">كود الاستلام من العميل</p>
        <p className="mt-1 text-2xl font-bold tracking-widest tabular-nums">{code}</p>
      </div>
    );
  }

  if (state === "unavailable") {
    return (
      <p className="rounded-lg border bg-muted/40 p-3 text-center text-sm text-muted-foreground">
        كود الاستلام غير متاح — تم إنشاء هذا الأوردر قبل إتاحة هذه الميزة
      </p>
    );
  }

  return (
    <Button type="button" variant="outline" className="w-full" onClick={reveal} disabled={state === "loading"}>
      {state === "loading" ? <Loader2 className="animate-spin" /> : <Eye />}
      إظهار كود الاستلام
    </Button>
  );
}
