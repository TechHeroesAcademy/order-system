import { notFound } from "next/navigation";
import { getOrderById, getOrderHistory, listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { requireRole } from "@/lib/auth";
import { OrderDetailView } from "@/components/orders/order-detail-view";

export default async function ModeratorOrderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const profile = await requireRole("owner", "moderator");

  const [order, history, regions, drivers] = await Promise.all([
    getOrderById(id),
    getOrderHistory(id),
    listRegions(),
    listStaff("driver"),
  ]);

  if (!order) notFound();

  const region = regions.find((r) => r.id === order.region_id) ?? null;
  const assignedDriver = drivers.find((d) => d.id === order.assigned_driver_id) ?? null;

  return (
    <OrderDetailView
      order={order}
      history={history}
      region={region}
      assignedDriverName={assignedDriver?.full_name ?? null}
      viewerProfile={profile}
      canManageDistribution
    />
  );
}
