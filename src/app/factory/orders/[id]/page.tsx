import { notFound } from "next/navigation";
import { getFactoryOrderById, getOrderHistory } from "@/lib/data/orders";
import { requireRole } from "@/lib/auth";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { OrderTimeline } from "@/components/orders/order-timeline";
import { OrderChat } from "@/components/orders/order-chat";
import { ConfirmActionButton } from "@/components/shared/confirm-action-button";
import { factoryConfirmReceiptAction, factoryMarkReadyAction } from "@/lib/actions/orders";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import { PackageCheck, CheckCircle2 } from "lucide-react";

/**
 * The factory's own order-detail page. Reuses factory_orders_view via
 * getFactoryOrderById — as of migration 0022, that means any order this
 * factory was ever assigned to resolves here permanently, including past
 * its own active window (with_driver/delivered/refused/cancelled), so the
 * "السجل" history tab on the dashboard has somewhere to link to. An order
 * that belongs to another factory, or an unassigned order that's no longer
 * active, still 404s here — see the comment on getFactoryOrderById
 * (src/lib/data/orders.ts) for why that part is unchanged.
 */
export default async function FactoryOrderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const profile = await requireRole("factory");

  const [order, history] = await Promise.all([getFactoryOrderById(id), getOrderHistory(id)]);
  if (!order) notFound();

  const delayed = isOrderDelayed(order.status, order.created_at);

  return (
    <div className="mx-auto max-w-xl space-y-4">
      <Card>
        <CardHeader className="flex-row items-center justify-between">
          <div>
            <CardTitle className="text-xl">{order.order_number}</CardTitle>
            <p className="text-sm text-muted-foreground">{formatDateTime(order.created_at)}</p>
          </div>
          <div className="flex items-center gap-2">
            {delayed && <Badge variant="warning">متأخر</Badge>}
            <OrderStatusBadge status={order.status} />
          </div>
        </CardHeader>
        <CardContent className="space-y-3">
          <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
            <div>
              <dt className="text-xs text-muted-foreground">عدد القطع</dt>
              <dd className="text-sm">{order.pieces_count}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">المندوب</dt>
              <dd className="text-sm">{order.assigned_driver_name ?? "—"}</dd>
            </div>
            {order.color && (
              <div>
                <dt className="text-xs text-muted-foreground">اللون</dt>
                <dd className="text-sm">{order.color}</dd>
              </div>
            )}
            {order.work_required && (
              <div className="sm:col-span-2">
                <dt className="text-xs text-muted-foreground">المطلوب عمله</dt>
                <dd className="text-sm">{order.work_required}</dd>
              </div>
            )}
            {order.piece_details && (
              <div className="sm:col-span-2">
                <dt className="text-xs text-muted-foreground">تفاصيل القطع</dt>
                <dd className="text-sm">{order.piece_details}</dd>
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

      <OrderChat orderId={order.id} channel="factory" viewerId={profile.id} />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">سجل حركة الأوردر</CardTitle>
        </CardHeader>
        <CardContent>
          <OrderTimeline entries={history} />
        </CardContent>
      </Card>
    </div>
  );
}
