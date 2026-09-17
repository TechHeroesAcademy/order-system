"use client";

import { useEffect, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { Search, PackageX, Check, Loader2 } from "lucide-react";
import { trackOrderSchema, type TrackOrderValues } from "@/lib/domain/validators";
import { trackOrderAction } from "@/lib/actions/orders";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { statusProgressPercent } from "@/lib/domain/order-status";
import { formatDateTime } from "@/lib/domain/format";
import { Badge } from "@/components/ui/badge";
import type { TrackedOrder } from "@/types/database";
import { cn } from "@/lib/utils";

/**
 * The order-tracking field: order number + phone, submits through
 * trackOrderAction, and renders the DHL-style step-tracker result below the
 * form once something comes back. Shared between the dedicated /track page
 * (wrapped there with a back link and outer card chrome) and the inline
 * field on the homepage itself, so a visitor can look up an order without
 * leaving "/" first.
 */
export function TrackOrderForm() {
  const [order, setOrder] = useState<TrackedOrder | null | undefined>(undefined);
  const [submitting, setSubmitting] = useState(false);
  const [progressWidth, setProgressWidth] = useState(0);

  const form = useForm<TrackOrderValues>({
    resolver: zodResolver(trackOrderSchema),
    defaultValues: { order_number: "", phone: "" },
  });

  async function onSubmit(values: TrackOrderValues) {
    setSubmitting(true);
    setProgressWidth(0);
    const res = await trackOrderAction(values);
    setSubmitting(false);
    if (!res.ok) {
      form.setError("order_number", { message: res.error });
      return;
    }
    setOrder(res.data);
  }

  // Animate the progress bar from 0 up to its real value every time a fresh
  // result arrives, instead of just snapping into place — the bar element
  // only exists once `order` is set, so the width has to be bumped a tick
  // after mount for the CSS transition to have something to animate from.
  useEffect(() => {
    if (!order) return;
    const target = statusProgressPercent(order.status);
    const frame = requestAnimationFrame(() => setProgressWidth(target));
    return () => cancelAnimationFrame(frame);
  }, [order]);

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
  const reachedCount = milestones.filter((m) => m.value).length;
  const isMoving = !!order && !order.delivered_at;

  return (
    <div className="space-y-6">
      <Form {...form}>
        <form onSubmit={form.handleSubmit(onSubmit)} className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <FormField
            control={form.control}
            name="order_number"
            render={({ field }) => (
              <FormItem className="flex-1">
                <FormLabel>رقم الأوردر</FormLabel>
                <FormControl>
                  <Input dir="ltr" placeholder="ORD-0001" className="h-11 text-base" {...field} />
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
                  <Input dir="ltr" placeholder="01xxxxxxxxx" className="h-11 text-base" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <Button
            type="submit"
            size="lg"
            disabled={submitting}
            className="h-11 rounded-full px-8 shadow-md hover:shadow-lg"
          >
            {submitting ? <Loader2 className="animate-spin" /> : <Search />}
            بحث
          </Button>
        </form>
      </Form>

      {order === null && (
        <div className="flex flex-col items-center gap-2 py-8 text-center text-muted-foreground animate-fade-in-up">
          <PackageX className="size-10" />
          <p>لا يوجد أوردر بهذه البيانات</p>
          <p className="text-sm">حاول التواصل مع الشخص الذي استلم أوردرك للتأكد من رقم الأوردر ورقم الهاتف</p>
        </div>
      )}

      {order && (
        <div className="space-y-6 border-t pt-4 animate-fade-in-up">
          <div className="flex items-center justify-between">
            <p className="font-bold" dir="ltr">
              {order.order_number}
            </p>
            <div className="flex items-center gap-2">
              {order.is_delayed && <Badge variant="warning">متأخر</Badge>}
              <OrderStatusBadge status={order.status} />
            </div>
          </div>

          <div className="relative h-2 w-full overflow-hidden rounded-full bg-muted">
            <div
              className={cn(
                "h-full rounded-full bg-primary transition-[width] duration-700 ease-out",
                isMoving && "animate-shimmer",
              )}
              style={{ width: `${progressWidth}%` }}
            />
          </div>

          {/* DHL-style step tracker: a row of filled/unfilled checkpoints
              with a connecting line, instead of a plain timestamp list. */}
          <ol className="flex items-start justify-between">
            {milestones.map((m, idx) => {
              const reached = !!m.value;
              const isNext = !reached && idx === reachedCount;
              return (
                <li key={m.label} className="flex flex-1 flex-col items-center gap-1.5 text-center">
                  <div className="flex w-full items-center">
                    <div
                      className={cn(
                        "h-0.5 flex-1 origin-left bg-primary transition-transform duration-500",
                        idx === 0 && "invisible",
                        reached ? "scale-x-100" : "scale-x-0",
                      )}
                    />
                    <div
                      className={cn(
                        "flex size-7 shrink-0 items-center justify-center rounded-full border-2 text-xs font-semibold transition-colors animate-pop-in",
                        reached
                          ? "border-primary bg-primary text-primary-foreground"
                          : isNext
                            ? "border-amber-600 bg-primary/15 text-amber-700 animate-pulse dark:border-amber-400 dark:text-amber-300"
                            : "border-muted-foreground/30 text-muted-foreground",
                      )}
                      style={{ animationDelay: `${idx * 90}ms` }}
                    >
                      {reached ? <Check className="size-3.5" /> : idx + 1}
                    </div>
                    <div
                      className={cn(
                        "h-0.5 flex-1 origin-right bg-primary transition-transform duration-500",
                        idx === milestones.length - 1 && "invisible",
                        !!milestones[idx + 1]?.value ? "scale-x-100" : "scale-x-0",
                      )}
                    />
                  </div>
                  <span
                    className={cn(
                      "hidden text-[11px] leading-tight sm:block",
                      reached ? "font-medium text-foreground" : "text-muted-foreground",
                    )}
                  >
                    {m.label}
                  </span>
                  {m.value && (
                    <span className="hidden text-[10px] text-muted-foreground sm:block">{formatDateTime(m.value)}</span>
                  )}
                </li>
              );
            })}
          </ol>
          {/* Labels are hidden per-step below sm (six Arabic labels don't
              fit six narrow columns on a phone) — show just the most
              recent milestone's label + time instead, DHL-app style. */}
          {milestones[reachedCount - 1] && (
            <p className="-mt-3 text-center text-xs text-muted-foreground sm:hidden">
              {milestones[reachedCount - 1].label} · {formatDateTime(milestones[reachedCount - 1].value)}
            </p>
          )}

          <p className="text-sm text-muted-foreground">عدد الأواني: {order.pieces_count}</p>
        </div>
      )}
    </div>
  );
}
