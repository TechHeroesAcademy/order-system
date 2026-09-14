import { Badge } from "@/components/ui/badge";
import { ORDER_STATUS_BADGE_VARIANT, ORDER_STATUS_LABELS_AR } from "@/lib/domain/order-status";
import type { OrderStatus } from "@/types/database";
import { cn } from "@/lib/utils";

export function OrderStatusBadge({ status, className }: { status: OrderStatus; className?: string }) {
  return (
    <Badge variant={ORDER_STATUS_BADGE_VARIANT[status]} className={cn(className)}>
      {ORDER_STATUS_LABELS_AR[status]}
    </Badge>
  );
}
