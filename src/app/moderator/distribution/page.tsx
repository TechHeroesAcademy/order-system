import { requireRole } from "@/lib/auth";
import { listStaff } from "@/lib/data/staff";
import { listFactories } from "@/lib/data/factories";
import { listPendingDistribution, listUnallocatedOrders } from "@/lib/data/distribution";
import { groupOrdersByRegion } from "@/lib/domain/distribution";
import { DistributionBoard } from "@/components/distribution/distribution-board";

/**
 * Lives under /moderator because that tree's layout is shared by both roles
 * (same reason /moderator/orders/new does) — a Manager reaching it through
 * their own nav lands here too. Both roles can read the board; only a Manager
 * can act on it, which is the same split the order-detail page already uses.
 */
export default async function DistributionPage({
  searchParams,
}: {
  searchParams: Promise<{ factory?: string }>;
}) {
  const profile = await requireRole("owner", "moderator");
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
      canApprove={profile.role === "owner"}
      activeFactoryId={factory ?? null}
    />
  );
}
