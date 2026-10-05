import { requireRole } from "@/lib/auth";
import { listStaff } from "@/lib/data/staff";
import { listFactories } from "@/lib/data/factories";
import { listPendingDistribution, listUnallocatedOrders } from "@/lib/data/distribution";
import { groupOrdersByRegion } from "@/lib/domain/distribution";
import { DistributionBoard } from "@/components/distribution/distribution-board";

export default async function DistributionPage({
  searchParams,
}: {
  searchParams: Promise<{ factory?: string }>;
}) {
  await requireRole("owner");
  const { factory } = await searchParams;

  const [pending, unallocated, drivers, factories] = await Promise.all([
    listPendingDistribution(factory),
    listUnallocatedOrders(),
    listStaff("driver"),
    listFactories(),
  ]);

  return (
    <DistributionBoard
      groups={groupOrdersByRegion(pending)}
      unallocated={unallocated}
      drivers={drivers.filter((d) => d.is_active)}
      factories={factories}
      canApprove
      activeFactoryId={factory ?? null}
    />
  );
}
