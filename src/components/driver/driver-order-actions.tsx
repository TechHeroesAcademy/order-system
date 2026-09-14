"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, PackageCheck, Factory, Truck, KeyRound, Ban } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { ConfirmActionButton } from "@/components/shared/confirm-action-button";
import {
  driverMarkCollectedAction,
  driverHandToFactoryAction,
  driverConfirmFactoryPickupAction,
  driverDeliverToCustomerAction,
  driverLogRefusalAction,
} from "@/lib/actions/orders";
import { deliveryCodeSchema, refusalReasonSchema } from "@/lib/domain/validators";
import type { Order } from "@/types/database";

export function DriverOrderActions({ order }: { order: Order }) {
  switch (order.status) {
    case "assigned":
      return (
        <Card>
          <CardContent className="pt-6">
            <ConfirmActionButton
              label="تم استلام الأوردر من العميل"
              confirmTitle="تأكيد استلام الأوردر"
              confirmDescription="تأكد أنك استلمت القطع فعليًا من العميل قبل التأكيد."
              onConfirm={() => driverMarkCollectedAction(order.id)}
              successMessage="تم تسجيل الاستلام من العميل"
              icon={<PackageCheck />}
            />
          </CardContent>
        </Card>
      );

    case "collected":
      return (
        <Card>
          <CardContent className="pt-6">
            <ConfirmActionButton
              label="تم التوجه بالأوردر للمصنع"
              confirmTitle="تأكيد تسليم الأوردر للمصنع"
              onConfirm={() => driverHandToFactoryAction(order.id)}
              successMessage="تم تسجيل التوجه للمصنع"
              icon={<Factory />}
            />
          </CardContent>
        </Card>
      );

    case "at_factory":
      return (
        <Card>
          <CardContent className="py-6 text-center text-sm text-muted-foreground">
            الأوردر داخل المصنع حاليًا — بانتظار تجهيزه.
          </CardContent>
        </Card>
      );

    case "ready":
      return (
        <Card>
          <CardContent className="pt-6">
            <ConfirmActionButton
              label="تم استلام الأوردر من المصنع"
              confirmTitle="تأكيد الاستلام من المصنع"
              onConfirm={() => driverConfirmFactoryPickupAction(order.id)}
              successMessage="تم تسجيل الاستلام من المصنع"
              icon={<Truck />}
            />
          </CardContent>
        </Card>
      );

    case "with_driver":
      return <DeliverToCustomerCard orderId={order.id} />;

    default:
      return null;
  }
}

function DeliverToCustomerCard({ orderId }: { orderId: string }) {
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submitDelivery() {
    const parsed = deliveryCodeSchema.safeParse({ code });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "كود غير صالح");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await driverDeliverToCustomerAction(orderId, parsed.data.code);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      if (!res.data.success) {
        setError("الكود غير صحيح — تأكد من الكود المكتوب على الإيصال مع العميل");
        setCode("");
        return;
      }
      toast.success("تم تسليم الأوردر للعميل بنجاح");
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">تسليم الأوردر للعميل</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-muted-foreground">اطلب من العميل كود التسليم المكتوب على الإيصال وأدخله هنا.</p>
        <Input
          inputMode="numeric"
          dir="ltr"
          placeholder="كود مكوّن من 4 أرقام"
          maxLength={4}
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
          className="text-center text-lg tracking-widest tabular-nums"
        />
        {error && <p className="text-sm text-destructive">{error}</p>}
        <Button className="w-full" onClick={submitDelivery} disabled={pending}>
          {pending && <Loader2 className="animate-spin" />}
          <KeyRound />
          تأكيد التسليم
        </Button>

        <RefusalDialog orderId={orderId} />
      </CardContent>
    </Card>
  );
}

function RefusalDialog({ orderId }: { orderId: string }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    const parsed = refusalReasonSchema.safeParse({ reason });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "اكتب سبب الرفض");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await driverLogRefusalAction(orderId, parsed.data.reason);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم تسجيل رفض الاستلام");
      setOpen(false);
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" className="w-full text-destructive hover:text-destructive">
          <Ban />
          العميل رفض الاستلام
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تسجيل رفض الاستلام</DialogTitle>
          <DialogDescription>اكتب سبب رفض العميل استلام الأوردر. لا يمكن التراجع عن هذا الإجراء.</DialogDescription>
        </DialogHeader>
        <Textarea value={reason} onChange={(e) => setReason(e.target.value)} placeholder="سبب الرفض..." rows={3} />
        {error && <p className="text-sm text-destructive">{error}</p>}
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button variant="destructive" onClick={submit} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            تأكيد الرفض
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
