import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { OrderStatusBadge } from "./order-status-badge";
import { OrderTimeline } from "./order-timeline";
import { DistributionPanel } from "./distribution-panel";
import { ChangeDriverButton } from "./change-driver-button";
import { CancelOrderButton } from "./cancel-order-button";
import { ConfirmActionButton } from "@/components/shared/confirm-action-button";
import { factoryConfirmReceiptAction, factoryMarkReadyAction } from "@/lib/actions/orders";
import { Badge } from "@/components/ui/badge";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import { PackageCheck, CheckCircle2 } from "lucide-react";
import type { Order, OrderHistoryEntry, Region, Profile } from "@/types/database";

const FIELD_LABELS: { key: keyof Order; label: string }[] = [
  { key: "customer_name", label: "اسم العميل" },
  { key: "customer_phone", label: "رقم الهاتف" },
  { key: "customer_address", label: "العنوان" },
  { key: "pieces_count", label: "عدد القطع" },
  { key: "piece_details", label: "تفاصيل القطع" },
  { key: "color", label: "اللون" },
  { key: "work_required", label: "المطلوب عمله" },
  { key: "customer_notes", label: "ملاحظات العميل" },
];

export function OrderDetailView({
  order,
  history,
  region,
  assignedDriverName,
  assignedFactoryName,
  viewerProfile,
  canManageDistribution,
  drivers = [],
}: {
  order: Order;
  history: OrderHistoryEntry[];
  region: Region | null;
  assignedDriverName: string | null;
  assignedFactoryName?: string | null;
  viewerProfile: Profile;
  canManageDistribution: boolean;
  /** Active drivers, for the "change driver" control below — only needed when canManageDistribution. */
  drivers?: Profile[];
}) {
  const delayed = isOrderDelayed(order.status, order.created_at);
  const isTerminal = ["delivered", "refused", "cancelled"].includes(order.status);

  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <div className="space-y-4 lg:col-span-2">
        <Card>
          <CardHeader className="flex-row items-center justify-between">
            <div>
              <CardTitle className="text-xl">{order.order_number}</CardTitle>
              <p className="text-sm text-muted-foreground">
                {order.source === "website" ? "أنشئ من الموقع" : "أنشئ عبر Messenger"} ·{" "}
                {formatDateTime(order.created_at)}
              </p>
            </div>
            <div className="flex items-center gap-2">
              {delayed && <Badge variant="warning">متأخر</Badge>}
              <OrderStatusBadge status={order.status} />
            </div>
          </CardHeader>
          <CardContent>
            <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
              {FIELD_LABELS.map(({ key, label }) => {
                const value = order[key];
                if (!value) return null;
                return (
                  <div key={key}>
                    <dt className="text-xs text-muted-foreground">{label}</dt>
                    <dd className="text-sm">{String(value)}</dd>
                  </div>
                );
              })}
              <div>
                <dt className="text-xs text-muted-foreground">المنطقة</dt>
                <dd className="text-sm">{region?.name ?? "—"}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">المندوب المسؤول</dt>
                <dd className="text-sm">{assignedDriverName ?? "لم يُسند بعد"}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">المصنع المخصص</dt>
                <dd className="text-sm">{assignedFactoryName ?? "بدون تحديد — يظهر لكل المصانع"}</dd>
              </div>
            </dl>

            {order.status === "refused" && order.refusal_reason && (
              <p className="mt-4 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
                سبب رفض الاستلام: {order.refusal_reason}
              </p>
            )}
            {order.status === "cancelled" && order.cancel_reason && (
              <p className="mt-4 rounded-lg border bg-muted p-3 text-sm text-muted-foreground">
                سبب الإلغاء: {order.cancel_reason}
              </p>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">سجل حركة الأوردر</CardTitle>
          </CardHeader>
          <CardContent>
            <OrderTimeline entries={history} />
          </CardContent>
        </Card>
      </div>

      <div className="space-y-4">
        {canManageDistribution && order.status === "new" && (
          <DistributionPanel
            orderId={order.id}
            assignedDriverId={order.assigned_driver_id}
            assignedDriverName={assignedDriverName}
            canApprove={viewerProfile.role === "owner"}
          />
        )}

        {canManageDistribution && !isTerminal && (
          <Card>
            <CardContent className="pt-6">
              <ChangeDriverButton orderId={order.id} currentDriverId={order.assigned_driver_id} drivers={drivers} />
            </CardContent>
          </Card>
        )}

        {/* Manual override for the factory step — the database already lets
            Owner/Moderator do this (not just the factory account), for when
            someone needs to correct or skip ahead without waiting on the
            factory dashboard. */}
        {canManageDistribution && (order.status === "collected" || order.status === "at_factory") && (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">إجراءات المصنع</CardTitle>
            </CardHeader>
            <CardContent className="pt-0">
              {order.status === "collected" && (
                <ConfirmActionButton
                  label="تأكيد استلام المصنع"
                  confirmTitle="تأكيد استلام الأوردر في المصنع"
                  onConfirm={() => factoryConfirmReceiptAction(order.id)}
                  successMessage="تم تأكيد الاستلام في المصنع"
                  icon={<PackageCheck />}
                  variant="outline"
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
                  variant="outline"
                />
              )}
            </CardContent>
          </Card>
        )}

        {canManageDistribution && !isTerminal && (
          <Card>
            <CardContent className="pt-6">
              <CancelOrderButton orderId={order.id} />
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
