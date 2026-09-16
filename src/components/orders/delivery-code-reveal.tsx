"use client";

import { useState } from "react";
import { Eye, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { getOrderDeliveryCodeAction } from "@/lib/actions/orders";

/**
 * The delivery code used to only ever be shown once, right after order
 * creation — by design, only a bcrypt hash was stored. Owner/Moderator can
 * now look it up again on demand (e.g. the customer lost their paper
 * receipt) via a dedicated RPC that keeps it out of reach of drivers — see
 * migration 0016. Click-to-reveal rather than shown by default, so it isn't
 * just sitting on screen for anyone glancing at the page.
 */
export function DeliveryCodeReveal({ orderId }: { orderId: string }) {
  const [state, setState] = useState<"hidden" | "loading" | "shown" | "unavailable">("hidden");
  const [code, setCode] = useState<string | null>(null);

  async function reveal() {
    setState("loading");
    const res = await getOrderDeliveryCodeAction(orderId);
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
        <p className="text-xs text-muted-foreground">كود تأكيد التسليم</p>
        <p className="mt-1 text-2xl font-bold tracking-widest tabular-nums">{code}</p>
      </div>
    );
  }

  if (state === "unavailable") {
    return (
      <p className="rounded-lg border bg-muted/40 p-3 text-center text-sm text-muted-foreground">
        كود التسليم غير متاح — تم إنشاء هذا الأوردر قبل إتاحة هذه الميزة
      </p>
    );
  }

  return (
    <Button type="button" variant="outline" className="w-full" onClick={reveal} disabled={state === "loading"}>
      {state === "loading" ? <Loader2 className="animate-spin" /> : <Eye />}
      إظهار كود التسليم
    </Button>
  );
}
