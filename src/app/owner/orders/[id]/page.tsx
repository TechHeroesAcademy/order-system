import { notFound } from "next/navigation";
import {
  getOrderById,
  getOrderCustomerContext,
  getOrderHistory,
  listRegions,
} from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { listFactories } from "@/lib/data/factories";
import { requireRole } from "@/lib/auth";
import { OrderDetailView } from "@/components/orders/order-detail-view";

export default async function OwnerOrderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const profile = await requireRole("owner");

  // customerContext is fetched alongside the rest, not after: it is one
  // indexed count, and serialising it behind the others would add a round
  // trip to every order page for a single line of text.
  const [order, history, regions, drivers, factories, customerContext] = await Promise.all([
    getOrderById(id),
    getOrderHistory(id),
    listRegions(),
    listStaff("driver"),
    listFactories(),
    getOrderCustomerContext(id),
  ]);

  if (!order) notFound();

  const region = regions.find((r) => r.id === order.region_id) ?? null;
  const assignedFactory = factories.find((f) => f.id === order.assigned_factory_id) ?? null;

  return (
    <OrderDetailView
      order={order}
      history={history}
      region={region}
      // Names come off the order's own snapshot columns (migration 0032),
      // not the live drivers/factories list — that list only has active
      // accounts, so a deleted worker's name would otherwise vanish here.
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
      customerContext={customerContext}
      orderBasePath="/owner/orders"
    />
  );
}
