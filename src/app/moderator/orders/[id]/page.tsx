import { notFound } from "next/navigation";
import { getOrderById, getOrderHistory, listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { listFactories } from "@/lib/data/factories";
import { requireRole } from "@/lib/auth";
import { OrderDetailView } from "@/components/orders/order-detail-view";

export default async function ModeratorOrderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const profile = await requireRole("owner", "moderator");

  const [order, history, regions, drivers, factories] = await Promise.all([
    getOrderById(id),
    getOrderHistory(id),
    listRegions(),
    listStaff("driver"),
    listFactories(),
  ]);

  if (!order) notFound();

  const region = regions.find((r) => r.id === order.region_id) ?? null;
  const assignedFactory = factories.find((f) => f.id === order.assigned_factory_id) ?? null;

  return (
    <OrderDetailView
      order={order}
      history={history}
      region={region}
      // See the same comment in owner/orders/[id]/page.tsx — snapshot
      // columns on the order, not a live staff lookup.
      assignedDriverName={order.assigned_driver_name}
      assignedFactoryName={order.assigned_factory_name}
      assignedFactoryAddress={assignedFactory?.address ?? null}
      assignedFactoryLat={assignedFactory?.lat ?? null}
      assignedFactoryLng={assignedFactory?.lng ?? null}
      assignedFactoryMapsUrl={assignedFactory?.maps_url ?? null}
      viewerProfile={profile}
      canManageDistribution
      drivers={drivers}
      factories={factories}
      regions={regions}
    />
  );
}
