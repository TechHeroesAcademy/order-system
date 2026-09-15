"use client";

import { Suspense, useState } from "react";
import Link from "next/link";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { ArrowRight, Search, PackageX } from "lucide-react";
import { trackOrderSchema, type TrackOrderValues } from "@/lib/domain/validators";
import { trackOrderAction } from "@/lib/actions/orders";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { statusProgressPercent } from "@/lib/domain/order-status";
import { formatDateTime } from "@/lib/domain/format";
import { Badge } from "@/components/ui/badge";
import { Loader2 } from "lucide-react";
import type { TrackedOrder } from "@/types/database";

export default function TrackPage() {
  return (
    <Suspense fallback={null}>
      <TrackForm />
    </Suspense>
  );
}

function TrackForm() {
  const [order, setOrder] = useState<TrackedOrder | null | undefined>(undefined);
  const [submitting, setSubmitting] = useState(false);

  const form = useForm<TrackOrderValues>({
    resolver: zodResolver(trackOrderSchema),
    defaultValues: { order_number: "", phone: "" },
  });

  async function onSubmit(values: TrackOrderValues) {
    setSubmitting(true);
    const res = await trackOrderAction(values);
    setSubmitting(false);
    if (!res.ok) {
      form.setError("order_number", { message: res.error });
      return;
    }
    setOrder(res.data);
  }

  const milestones: { label: string; value: string | null }[] = order
    ? [
        { label: "تم إنشاء الأوردر", value: order.created_at },
        { label: "تم الاستلام من العميل", value: order.collected_at },
        { label: "دخل المصنع", value: order.factory_received_at },
        { label: "جاهز للتسليم", value: order.factory_ready_at },
        { label: "خرج مع المندوب", value: order.driver_pickup_at },
        { label: "تم التسليم", value: order.delivered_at },
      ]
    : [];

  return (
    <main className="mx-auto min-h-screen max-w-xl p-4 py-8">
      <Link href="/" className="mb-4 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
        <ArrowRight className="size-4" />
        رجوع
      </Link>
      <Card>
        <CardHeader>
          <CardTitle>تتبع الأوردر</CardTitle>
          <CardDescription>أدخل رقم الأوردر ورقم الهاتف المسجل به</CardDescription>
        </CardHeader>
        <CardContent className="space-y-6">
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmit)} className="flex flex-col gap-4 sm:flex-row sm:items-end">
              <FormField
                control={form.control}
                name="order_number"
                render={({ field }) => (
                  <FormItem className="flex-1">
                    <FormLabel>رقم الأوردر</FormLabel>
                    <FormControl>
                      <Input dir="ltr" placeholder="ORD-0001" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={form.control}
                name="phone"
                render={({ field }) => (
                  <FormItem className="flex-1">
                    <FormLabel>رقم الهاتف</FormLabel>
                    <FormControl>
                      <Input dir="ltr" placeholder="01xxxxxxxxx" {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <Button type="submit" disabled={submitting}>
                {submitting ? <Loader2 className="animate-spin" /> : <Search />}
                بحث
              </Button>
            </form>
          </Form>

          {order === null && (
            <div className="flex flex-col items-center gap-2 py-8 text-center text-muted-foreground">
              <PackageX className="size-10" />
              <p>لا يوجد أوردر بهذه البيانات</p>
              <p className="text-sm">حاول التواصل مع الشخص الذي استلم أوردرك للتأكد من رقم الأوردر ورقم الهاتف</p>
            </div>
          )}

          {order && (
            <div className="space-y-4 border-t pt-4">
              <div className="flex items-center justify-between">
                <p className="font-bold">{order.order_number}</p>
                <div className="flex items-center gap-2">
                  {order.is_delayed && <Badge variant="warning">متأخر</Badge>}
                  <OrderStatusBadge status={order.status} />
                </div>
              </div>

              <div className="h-2 w-full overflow-hidden rounded-full bg-muted">
                <div
                  className="h-full bg-primary transition-all"
                  style={{ width: `${statusProgressPercent(order.status)}%` }}
                />
              </div>

              <ul className="space-y-2 text-sm">
                {milestones
                  .filter((m) => m.value)
                  .map((m) => (
                    <li key={m.label} className="flex items-center justify-between">
                      <span>{m.label}</span>
                      <span className="text-muted-foreground">{formatDateTime(m.value)}</span>
                    </li>
                  ))}
              </ul>
              <p className="text-sm text-muted-foreground">عدد القطع: {order.pieces_count}</p>
            </div>
          )}
        </CardContent>
      </Card>
    </main>
  );
}
