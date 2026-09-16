"use client";

import Link from "next/link";
import { PackageCheck, CheckCircle2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { ConfirmActionButton } from "@/components/shared/confirm-action-button";
import { factoryConfirmReceiptAction, factoryMarkReadyAction } from "@/lib/actions/orders";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import type { FactoryOrderRow } from "@/types/database";

export function FactoryOrderCard({ order }: { order: FactoryOrderRow }) {
  const delayed = isOrderDelayed(order.status, order.created_at);

  return (
    <Card className="transition-[transform,box-shadow] duration-200 hover:-translate-y-0.5 hover:shadow-md">
      <CardContent className="space-y-3 py-4">
        <div className="flex items-center justify-between">
          <Link href={`/factory/orders/${order.id}`} className="font-bold hover:underline">
            {order.order_number}
          </Link>
          <div className="flex items-center gap-1.5">
            {delayed && <Badge variant="warning">متأخر</Badge>}
            <OrderStatusBadge status={order.status} />
          </div>
        </div>

        <dl className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-sm">
          <div>
            <dt className="text-xs text-muted-foreground">عدد القطع</dt>
            <dd>{order.pieces_count}</dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">المندوب</dt>
            <dd>{order.assigned_driver_name ?? "—"}</dd>
          </div>
          {order.color && (
            <div>
              <dt className="text-xs text-muted-foreground">اللون</dt>
              <dd>{order.color}</dd>
            </div>
          )}
          {order.work_required && (
            <div className="col-span-2">
              <dt className="text-xs text-muted-foreground">المطلوب عمله</dt>
              <dd>{order.work_required}</dd>
            </div>
          )}
          {order.piece_details && (
            <div className="col-span-2">
              <dt className="text-xs text-muted-foreground">تفاصيل القطع</dt>
              <dd>{order.piece_details}</dd>
            </div>
          )}
        </dl>

        {order.status === "collected" && (
          <ConfirmActionButton
            label="تأكيد استلام الأوردر"
            confirmTitle="تأكيد استلام الأوردر في المصنع"
            onConfirm={() => factoryConfirmReceiptAction(order.id)}
            successMessage="تم تأكيد الاستلام"
            icon={<PackageCheck />}
          />
        )}

        {order.status === "at_factory" && (
          <ConfirmActionButton
            label="الأوردر جاهز للتسليم"
            confirmTitle="تأكيد جاهزية الأوردر"
            confirmDescription="سيتم إشعار المندوب المسؤول لاستلام الأوردر."
            onConfirm={() => factoryMarkReadyAction(order.id)}
            successMessage="تم تجهيز الأوردر للتسليم"
            icon={<CheckCircle2 />}
          />
        )}

        {order.status === "ready" && (
          <p className="rounded-md border bg-muted/40 p-2 text-center text-sm text-muted-foreground">
            بانتظار استلام المندوب — {formatDateTime(order.factory_ready_at)}
          </p>
        )}
      </CardContent>
    </Card>
  );
}
