import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { OrderStatusBadge } from "./order-status-badge";
import { OrderTimeline } from "./order-timeline";
import { DistributionPanel } from "./distribution-panel";
import { ChangeDriverButton } from "./change-driver-button";
import { ChangeFactoryButton } from "./change-factory-button";
import { CancelOrderButton } from "./cancel-order-button";
import { EditOrderDialog } from "./edit-order-dialog";
import { OrderChat } from "./order-chat";
import { ConfirmActionButton } from "@/components/shared/confirm-action-button";
import { factoryConfirmReceiptAction, factoryMarkReadyAction } from "@/lib/actions/orders";
import { DeliveryCodeReveal } from "./delivery-code-reveal";
import { PickupCodeReveal } from "./pickup-code-reveal";
import { Badge } from "@/components/ui/badge";
import { formatDateTime } from "@/lib/domain/format";
import { isOrderDelayed } from "@/lib/domain/order-status";
import { mapsUrlFor } from "@/lib/domain/maps";
import { PackageCheck, CheckCircle2, MapPin } from "lucide-react";
import type { Order, OrderHistoryEntry, Region, Profile } from "@/types/database";

// customer_address is rendered separately below (with a Maps link), not
// through this generic loop.
const FIELD_LABELS: { key: keyof Order; label: string }[] = [
  { key: "customer_name", label: "اسم العميل" },
  { key: "customer_phone", label: "رقم الهاتف" },
  { key: "pieces_count", label: "عدد الأواني" },
  { key: "piece_details", label: "تفاصيل الإناء" },
  { key: "color", label: "اللون" },
  { key: "work_required", label: "نوع الخدمة المطلوبة" },
  { key: "customer_notes", label: "ملاحظات العميل" },
];

export function OrderDetailView({
  order,
  history,
  region,
  assignedDriverName,
  assignedFactoryName,
  assignedFactoryAddress,
  assignedFactoryLat,
  assignedFactoryLng,
  assignedFactoryMapsUrl,
  viewerProfile,
  canManageDistribution,
  drivers = [],
  factories = [],
  regions = [],
}: {
  order: Order;
  history: OrderHistoryEntry[];
  region: Region | null;
  assignedDriverName: string | null;
  assignedFactoryName?: string | null;
  assignedFactoryAddress?: string | null;
  assignedFactoryLat?: number | null;
  assignedFactoryLng?: number | null;
  assignedFactoryMapsUrl?: string | null;
  viewerProfile: Profile;
  canManageDistribution: boolean;
  /** Active drivers, for the "change driver" control below — only needed when canManageDistribution. */
  drivers?: Profile[];
  /** Active factories, for the "change factory" control below — only needed when canManageDistribution. */
  factories?: Profile[];
  /** All regions, for the edit-order dialog's region picker — only needed when canManageDistribution. */
  regions?: Region[];
}) {
  const delayed = isOrderDelayed(order.status, order.created_at);
  const isTerminal = ["delivered", "refused", "cancelled"].includes(order.status);
  // Assigning/changing who handles an order (driver or factory) is Manager-
  // only (migration 0024), and so is cancelling it (migration 0030) — both
  // gated on canAssign below. Everything else canManageDistribution gates
  // (editing order details, the delivery/pickup codes, chat) stays
  // available to Moderator too.
  const canAssign = viewerProfile.role === "owner";

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
              {canManageDistribution && <EditOrderDialog order={order} regions={regions} />}
            </div>
          </CardHeader>
          <CardContent>
            <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-2">
              <div>
                <dt className="text-xs text-muted-foreground">اسم العميل</dt>
                <dd className="text-sm">{order.customer_name}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">رقم الهاتف</dt>
                <dd className="text-sm">{order.customer_phone}</dd>
              </div>
              <div>
                <dt className="text-xs text-muted-foreground">العنوان</dt>
                <dd className="text-sm">
                  {order.customer_address}
                  {(() => {
                    const url = mapsUrlFor({ maps_url: order.customer_maps_url, address: order.customer_address });
                    if (!url) return null;
                    return (
                      <a
                        href={url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="mt-0.5 flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground hover:underline"
                      >
                        <MapPin className="size-3" />
                        فتح في خرائط جوجل
                      </a>
                    );
                  })()}
                </dd>
              </div>
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
                <dd className="text-sm">
                  {assignedFactoryName ?? "بدون تحديد — يظهر لكل المصانع"}
                  {assignedFactoryName && assignedFactoryAddress && (
                    <span className="block text-xs text-muted-foreground">{assignedFactoryAddress}</span>
                  )}
                  {assignedFactoryName &&
                    (() => {
                      const url = mapsUrlFor({
                        maps_url: assignedFactoryMapsUrl,
                        address: assignedFactoryAddress,
                        lat: assignedFactoryLat,
                        lng: assignedFactoryLng,
                      });
                      if (!url) return null;
                      return (
                        <a
                          href={url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="mt-0.5 flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground hover:underline"
                        >
                          <MapPin className="size-3" />
                          فتح في خرائط جوجل
                        </a>
                      );
                    })()}
                </dd>
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
        {canManageDistribution && (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">كود التسليم</CardTitle>
            </CardHeader>
            <CardContent className="pt-0">
              <DeliveryCodeReveal orderId={order.id} />
            </CardContent>
          </Card>
        )}

        {canManageDistribution && (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">كود الاستلام من العميل</CardTitle>
            </CardHeader>
            <CardContent className="pt-0">
              <PickupCodeReveal orderId={order.id} />
            </CardContent>
          </Card>
        )}

        {canManageDistribution && order.status === "new" && (
          <DistributionPanel
            orderId={order.id}
            assignedDriverId={order.assigned_driver_id}
            assignedDriverName={assignedDriverName}
            canAssign={canAssign}
            canApprove={viewerProfile.role === "owner"}
          />
        )}

        {canAssign && !isTerminal && (
          <Card>
            <CardContent className="space-y-2 pt-6">
              <ChangeDriverButton orderId={order.id} currentDriverId={order.assigned_driver_id} drivers={drivers} />
              <ChangeFactoryButton orderId={order.id} currentFactoryId={order.assigned_factory_id} factories={factories} />
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
              {/* .bind(null, order.id), not () => factoryConfirmReceiptAction(order.id) — this
                  component is a Server Component and ConfirmActionButton is a Client
                  Component, so onConfirm has to cross that boundary. A real Server Action
                  reference survives that (Next.js serializes it specially, including a
                  .bind()'s pre-bound args), but a plain arrow-function closure wrapping one
                  does not — React throws "Event handlers cannot be passed to Client
                  Component props" the instant this renders. Since this card shows for
                  Owner/Moderator on any order sitting at collected/at_factory, this crashed
                  the order-detail page for both roles too, not just the factory account's
                  own page (digest 250852290). */}
              {order.status === "collected" && (
                <ConfirmActionButton
                  label="تأكيد استلام المصنع"
                  confirmTitle="تأكيد استلام الأوردر في المصنع"
                  onConfirm={factoryConfirmReceiptAction.bind(null, order.id)}
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
                  onConfirm={factoryMarkReadyAction.bind(null, order.id)}
                  successMessage="تم تجهيز الأوردر للتسليم"
                  icon={<CheckCircle2 />}
                  variant="outline"
                />
              )}
            </CardContent>
          </Card>
        )}

        {canAssign && !isTerminal && (
          <Card>
            <CardContent className="pt-6">
              <CancelOrderButton orderId={order.id} />
            </CardContent>
          </Card>
        )}

        {canManageDistribution && (
          <>
            <OrderChat orderId={order.id} channel="driver" viewerId={viewerProfile.id} />
            <OrderChat orderId={order.id} channel="factory" viewerId={viewerProfile.id} />
          </>
        )}
      </div>
    </div>
  );
}
