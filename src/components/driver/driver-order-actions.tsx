"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, PackageCheck, Factory, Truck, KeyRound, Ban, MapPin, Clock } from "lucide-react";
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
import { formatDateTime } from "@/lib/domain/format";
import type { Order } from "@/types/database";

type FactoryInfo = { full_name: string; address: string | null } | null;

/** Small "which factory / where" strip shown alongside every factory-related step below. */
function FactoryLocationNote({ factory }: { factory: FactoryInfo }) {
  return (
    <div className="mb-3 flex items-start gap-2 rounded-lg border bg-accent/40 p-3 text-sm">
      <Factory className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      <div className="min-w-0 flex-1">
        <p className="font-medium">{factory?.full_name ?? "لم يُحدد مصنع لهذا الأوردر"}</p>
        {factory?.address ? (
          <a
            href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(factory.address)}`}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-0.5 flex items-center gap-1 text-muted-foreground hover:text-foreground hover:underline"
          >
            <MapPin className="size-3.5 shrink-0" />
            {factory.address}
          </a>
        ) : (
          factory && <p className="mt-0.5 text-xs text-muted-foreground">لا يوجد عنوان مسجل لهذا المصنع بعد</p>
        )}
      </div>
    </div>
  );
}

export function DriverOrderActions({ order, factory = null }: { order: Order; factory?: FactoryInfo }) {
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
      // Status stays 'collected' through this whole step — only the factory
      // confirming receipt moves it to 'at_factory' — so handed_to_factory_at
      // (not order.status) is what tells "not handed off yet" apart from
      // "handed off, now waiting on the factory to confirm". Without this,
      // the same button kept reappearing after being pressed, which read as
      // the step not having registered at all.
      return (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">التوجه للمصنع</CardTitle>
          </CardHeader>
          <CardContent className="pt-0">
            <FactoryLocationNote factory={factory} />
            {order.handed_to_factory_at ? (
              <div className="flex items-center gap-2 rounded-lg border py-3 px-3 text-sm text-muted-foreground">
                <Clock className="size-4 shrink-0" />
                تم تسجيل توجهك للمصنع {formatDateTime(order.handed_to_factory_at)} — بانتظار تأكيد الاستلام من المصنع.
              </div>
            ) : (
              <ConfirmActionButton
                label="تم التوجه بالأوردر للمصنع"
                confirmTitle="تأكيد تسليم الأوردر للمصنع"
                onConfirm={() => driverHandToFactoryAction(order.id)}
                successMessage="تم تسجيل التوجه للمصنع"
                icon={<Factory />}
              />
            )}
          </CardContent>
        </Card>
      );

    case "at_factory":
      return (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">داخل المصنع</CardTitle>
          </CardHeader>
          <CardContent className="pt-0">
            <FactoryLocationNote factory={factory} />
            <p className="py-3 text-center text-sm text-muted-foreground">
              الأوردر داخل المصنع حاليًا — بانتظار تجهيزه. لا يمكنك استلامه إلا بعد أن يضغط المصنع &quot;جاهز للتسليم&quot;.
            </p>
          </CardContent>
        </Card>
      );

    case "ready":
      return (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">جاهز للاستلام من المصنع</CardTitle>
          </CardHeader>
          <CardContent className="pt-0">
            <FactoryLocationNote factory={factory} />
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
  const router = useRouter();

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
      router.refresh();
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
  const router = useRouter();

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
      router.refresh();
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
