import Link from "next/link";
import { requireRole } from "@/lib/auth";
import { listMyDriverOrders, listRegions } from "@/lib/data/orders";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { EmptyState } from "@/components/shared/empty-state";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import { PackageSearch } from "lucide-react";

export default async function DriverOrdersPage() {
  const profile = await requireRole("driver");
  // The completed tab has always shown at most 30 cards, so only 30 are
  // fetched. completedTotal is the exact database count, so the tab's
  // number is the same one it displayed when the whole history was loaded.
  const COMPLETED_SHOWN = 30;
  const [{ active, completed, completedTotal }, regions] = await Promise.all([
    listMyDriverOrders(profile.id, COMPLETED_SHOWN),
    listRegions(),
  ]);

  const regionName = (id: string | null) => regions.find((r) => r.id === id)?.name ?? "—";

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">أوردراتي</h1>

      <Tabs defaultValue="active">
        <TabsList>
          <TabsTrigger value="active">نشطة ({active.length})</TabsTrigger>
          <TabsTrigger value="completed">مكتملة ({completedTotal})</TabsTrigger>
        </TabsList>

        <TabsContent value="active" className="pt-3">
          {active.length === 0 ? (
            <EmptyState icon={PackageSearch} title="لا يوجد أوردرات نشطة حاليًا" />
          ) : (
            <ul className="stagger-children space-y-2">
              {active.map((order) => {
                const delayed = isOrderDelayed(order.status, order.created_at);
                return (
                  <li key={order.id}>
                    <Link href={`/driver/orders/${order.id}`}>
                      <Card className="transition-[transform,box-shadow,background-color] duration-200 hover:-translate-y-0.5 hover:bg-accent/40 hover:shadow-md">
                        <CardContent className="flex items-center justify-between gap-3 py-3">
                          <div className="min-w-0">
                            <div className="flex items-center gap-1.5">
                              <span className="font-medium">{order.order_number}</span>
                              {delayed && <Badge variant="warning">متأخر</Badge>}
                            </div>
                            <p className="truncate text-sm text-muted-foreground">
                              {order.customer_name} · {regionName(order.region_id)}
                            </p>
                            <p className="text-xs text-muted-foreground">{order.customer_address}</p>
                          </div>
                          <OrderStatusBadge status={order.status} className="shrink-0" />
                        </CardContent>
                      </Card>
                    </Link>
                  </li>
                );
              })}
            </ul>
          )}
        </TabsContent>

        <TabsContent value="completed" className="pt-3">
          {completedTotal === 0 ? (
            <EmptyState icon={PackageSearch} title="لا يوجد أوردرات مكتملة بعد" />
          ) : (
            <ul className="stagger-children space-y-2">
              {completed.map((order) => (
                <li key={order.id}>
                  <Link href={`/driver/orders/${order.id}`}>
                    <Card className="transition-[transform,box-shadow,background-color] duration-200 hover:-translate-y-0.5 hover:bg-accent/40 hover:shadow-md">
                      <CardContent className="flex items-center justify-between gap-3 py-3">
                        <div className="min-w-0">
                          <span className="font-medium">{order.order_number}</span>
                          <p className="truncate text-sm text-muted-foreground">
                            {order.customer_name} · {formatDateTime(order.delivered_at ?? order.refused_at)}
                          </p>
                        </div>
                        <OrderStatusBadge status={order.status} className="shrink-0" />
                      </CardContent>
                    </Card>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </TabsContent>
      </Tabs>
    </div>
  );
}
