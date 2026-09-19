import Link from "next/link";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { OrderStatusBadge } from "./order-status-badge";
import { ChangeDriverButton } from "./change-driver-button";
import { ChangeFactoryButton } from "./change-factory-button";
import { CancelOrderButton } from "./cancel-order-button";
import { DeliveryCodeCell } from "./delivery-code-cell";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/shared/empty-state";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import { PackageSearch } from "lucide-react";
import type { OrderListRow } from "@/lib/data/orders";
import type { Region, Profile, Factory } from "@/types/database";

const TERMINAL_STATUSES = new Set(["delivered", "refused", "cancelled"]);

export function OrdersTable({
  orders,
  basePath,
  drivers = [],
  factories = [],
  deliveryCodes = {},
  canAssign = false,
}: {
  orders: OrderListRow[];
  regions: Region[];
  basePath: string;
  /** Active drivers, for the inline "change driver" action — Owner only, see canAssign. */
  drivers?: Profile[];
  /** Active factories, for the inline "change factory" action — Owner only, see canAssign. */
  factories?: Factory[];
  /** Delivery codes for this page's orders, keyed by order id — batch-fetched once by the page (see getOrderDeliveryCodesMap). */
  deliveryCodes?: Record<string, string>;
  /** Owner only (migration 0024/0030) — shows the inline change-driver/change-factory buttons and the cancel button. A Moderator still sees everything else in this row (status, codes). */
  canAssign?: boolean;
}) {
  if (orders.length === 0) {
    return <EmptyState icon={PackageSearch} title="لا يوجد أوردرات مطابقة" />;
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>رقم الأوردر</TableHead>
          <TableHead>العميل</TableHead>
          <TableHead>المنطقة</TableHead>
          <TableHead>المندوب</TableHead>
          <TableHead>المصنع</TableHead>
          <TableHead>كود التسليم</TableHead>
          <TableHead>الحالة</TableHead>
          <TableHead>تاريخ الإنشاء</TableHead>
          <TableHead className="text-center">إجراءات</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {orders.map((order) => {
          const delayed = isOrderDelayed(order.status, order.created_at);
          const isTerminal = TERMINAL_STATUSES.has(order.status);
          return (
            <TableRow key={order.id}>
              <TableCell>
                <Link href={`${basePath}/${order.id}`} className="font-medium hover:underline">
                  {order.order_number}
                </Link>
              </TableCell>
              <TableCell>
                <div>{order.customer_name}</div>
                <div className="text-xs text-muted-foreground" dir="ltr">
                  {order.customer_phone}
                </div>
              </TableCell>
              <TableCell>{order.region?.name ?? "—"}</TableCell>
              <TableCell>{order.assigned_driver_name ?? "—"}</TableCell>
              <TableCell>{order.assigned_factory_name ?? "—"}</TableCell>
              <TableCell>
                <DeliveryCodeCell code={deliveryCodes[order.id] ?? null} />
              </TableCell>
              <TableCell>
                <div className="flex items-center gap-1.5">
                  {delayed && <Badge variant="warning">متأخر</Badge>}
                  <OrderStatusBadge status={order.status} />
                </div>
              </TableCell>
              <TableCell className="text-muted-foreground">{formatDateTime(order.created_at)}</TableCell>
              <TableCell>
                {isTerminal || !canAssign ? (
                  <p className="text-center text-xs text-muted-foreground">—</p>
                ) : (
                  <div className="flex items-center justify-center gap-0.5">
                    <ChangeDriverButton
                      orderId={order.id}
                      currentDriverId={order.assigned_driver_id}
                      drivers={drivers}
                      compact
                    />
                    <ChangeFactoryButton
                      orderId={order.id}
                      currentFactoryId={order.assigned_factory_id}
                      factories={factories}
                      compact
                    />
                    <CancelOrderButton orderId={order.id} compact />
                  </div>
                )}
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
