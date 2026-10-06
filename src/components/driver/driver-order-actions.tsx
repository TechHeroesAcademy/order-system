"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, PackageCheck, Factory as FactoryIcon, Truck, KeyRound, Ban, MapPin, Repeat } from "lucide-react";
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
  driverConfirmFactoryPickupAction,
  factoryConfirmReceiptAction,
  factoryMarkReadyAction,
  driverDeliverToCustomerAction,
  driverLogRefusalAction,
  retryDeliveryAction,
} from "@/lib/actions/orders";
import { deliveryCodeSchema, pickupCodeSchema, refusalReasonSchema } from "@/lib/domain/validators";
import { mapsUrlFor } from "@/lib/domain/maps";
import type { Order } from "@/types/database";

type FactoryInfo = {
  name: string;
  address: string | null;
  lat?: number | null;
  lng?: number | null;
  maps_url?: string | null;
} | null;

function FactoryLocationNote({ factory }: { factory: FactoryInfo }) {
  const mapsUrl = factory ? mapsUrlFor(factory) : null;
  return (
    <div className="mb-3 flex items-start gap-2 rounded-lg border bg-accent/40 p-3 text-sm">
      <FactoryIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      <div className="min-w-0 flex-1">
        <p className="font-medium">{factory?.name ?? "لم يُحدد مصنع لهذا الأوردر"}</p>
        {mapsUrl ? (
          <a
            href={mapsUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-0.5 flex items-center gap-1 text-muted-foreground hover:text-foreground hover:underline"
          >
            <MapPin className="size-3.5 shrink-0" />
            {factory?.address ?? "فتح الموقع في خرائط جوجل"}
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
      return <CollectFromCustomerCard orderId={order.id} />;

    case "collected":
      return (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">تسليم الأوردر للمصنع</CardTitle>
          </CardHeader>
          <CardContent className="pt-0">
            <FactoryLocationNote factory={factory} />
            <ConfirmActionButton
              label="سلّمت الأوردر للمصنع"
              confirmTitle="تأكيد تسليم الأوردر للمصنع"
              confirmDescription="اضغط بعد تسليم الأوردر فعليًا في المصنع."
              onConfirm={() => factoryConfirmReceiptAction(order.id)}
              successMessage="تم تسجيل تسليم الأوردر للمصنع"
              icon={<FactoryIcon />}
            />
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
            <p className="mb-3 text-sm text-muted-foreground">
              الأوردر داخل المصنع حاليًا. اضغط بعد ما المصنع يخلّص الشغل عشان تقدر تستلمه.
            </p>
            <ConfirmActionButton
              label="المصنع خلّص الشغل"
              confirmTitle="تأكيد جاهزية الأوردر"
              confirmDescription="اضغط بعد ما المصنع ينهي العمل في الأوردر فعليًا."
              onConfirm={() => factoryMarkReadyAction(order.id)}
              successMessage="تم تسجيل جاهزية الأوردر"
              icon={<PackageCheck />}
            />
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

    case "refused":
      return <RetryDeliveryCard orderId={order.id} reason={order.refusal_reason} />;

    default:
      return null;
  }
}

function RetryDeliveryCard({
  orderId,
  reason,
}: {
  orderId: string;
  reason?: string | null;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">العميل رفض الاستلام</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 pt-0">
        {reason ? (
          <p className="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
            السبب المسجّل: {reason}
          </p>
        ) : null}
        <p className="text-sm text-muted-foreground">
          لو اتفقت مع العميل على ميعاد تاني، افتح الأوردر للتسليم مرة أخرى. كود
          التسليم هو نفسه ولم يتغير.
        </p>
        <ConfirmActionButton
          label="حاول التسليم مرة أخرى"
          confirmTitle="إعادة فتح الأوردر للتسليم"
          confirmDescription="هيرجع الأوردر لحالة (مع المندوب) وتقدر تسلّمه في ميعاد تاني بنفس الكود."
          onConfirm={() => retryDeliveryAction(orderId)}
          successMessage="تم فتح الأوردر للتسليم مرة أخرى"
          icon={<Repeat />}
        />
      </CardContent>
    </Card>
  );
}

function CollectFromCustomerCard({ orderId }: { orderId: string }) {
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  function submitCollection() {
    const parsed = pickupCodeSchema.safeParse({ code });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "كود غير صالح");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await driverMarkCollectedAction(orderId, parsed.data.code);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      if (!res.data.success) {
        setError("الكود غير صحيح — تأكد من الكود مع العميل");
        setCode("");
        return;
      }
      toast.success("تم تسجيل الاستلام من العميل");
      router.refresh();
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">استلام الأوردر من العميل</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-muted-foreground">اطلب من العميل كود الاستلام وأدخله هنا لتأكيد أنك استلمت القطع فعليًا.</p>
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
        <Button className="w-full" onClick={submitCollection} disabled={pending}>
          {pending && <Loader2 className="animate-spin" />}
          <PackageCheck />
          تأكيد الاستلام
        </Button>
      </CardContent>
    </Card>
  );
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
