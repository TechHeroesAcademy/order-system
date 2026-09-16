import { notFound } from "next/navigation";
import { getOrderById, getOrderHistory, listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { requireRole } from "@/lib/auth";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { OrderTimeline } from "@/components/orders/order-timeline";
import { DriverOrderActions } from "@/components/driver/driver-order-actions";
import { OrderChat } from "@/components/orders/order-chat";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import { googleMapsSearchUrl } from "@/lib/domain/maps";

export default async function DriverOrderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const profile = await requireRole("driver");

  const [order, history, regions, factories] = await Promise.all([
    getOrderById(id),
    getOrderHistory(id),
    listRegions(),
    listStaff("factory"),
  ]);

  if (!order) notFound();
  if (order.assigned_driver_id !== profile.id) notFound();

  const region = regions.find((r) => r.id === order.region_id) ?? null;
  const assignedFactory = factories.find((f) => f.id === order.assigned_factory_id) ?? null;
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
              <dt className="text-xs text-muted-foreground">اسم العميل</dt>
              <dd className="text-sm">{order.customer_name}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">رقم الهاتف</dt>
              <dd className="text-sm" dir="ltr">
                {order.customer_phone}
              </dd>
            </div>
            <div className="sm:col-span-2">
              <dt className="text-xs text-muted-foreground">العنوان</dt>
              <dd className="text-sm">{order.customer_address}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">المنطقة</dt>
              <dd className="text-sm">{region?.name ?? "—"}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">عدد القطع</dt>
              <dd className="text-sm">{order.pieces_count}</dd>
            </div>
            {order.piece_details && (
              <div>
                <dt className="text-xs text-muted-foreground">تفاصيل القطع</dt>
                <dd className="text-sm">{order.piece_details}</dd>
              </div>
            )}
            {order.work_required && (
              <div>
                <dt className="text-xs text-muted-foreground">المطلوب عمله</dt>
                <dd className="text-sm">{order.work_required}</dd>
              </div>
            )}
          </dl>

          <div className="grid grid-cols-2 gap-2">
            <a
              href={`tel:${order.customer_phone}`}
              className="block rounded-lg border bg-accent/40 p-3 text-center text-sm font-medium hover:bg-accent"
            >
              اتصال بالعميل
            </a>
            <a
              href={googleMapsSearchUrl(order.customer_address)}
              target="_blank"
              rel="noopener noreferrer"
              className="block rounded-lg border bg-accent/40 p-3 text-center text-sm font-medium hover:bg-accent"
            >
              فتح الموقع على الخريطة
            </a>
          </div>
        </CardContent>
      </Card>

      <DriverOrderActions
        order={order}
        factory={
          assignedFactory
            ? {
                full_name: assignedFactory.full_name,
                address: assignedFactory.address,
                lat: assignedFactory.lat,
                lng: assignedFactory.lng,
              }
            : null
        }
      />

      <OrderChat orderId={order.id} channel="driver" viewerId={profile.id} />

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
