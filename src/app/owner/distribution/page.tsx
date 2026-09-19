import { requireRole } from "@/lib/auth";
import { listStaff } from "@/lib/data/staff";
import { listFactories } from "@/lib/data/factories";
import { listPendingDistribution, listUnallocatedOrders } from "@/lib/data/distribution";
import { groupOrdersByRegion } from "@/lib/domain/distribution";
import { DistributionBoard } from "@/components/distribution/distribution-board";

/**
 * Manager-only, and living under /owner for that reason.
 *
 * It used to sit under /moderator and be readable by both roles, with only a
 * Manager able to act. That was wrong twice over. Every RPC behind this board
 * — set_order_distribution, approve_distribution, and their bulk forms — has
 * always been is_owner(), so a Moderator got a screen whose every button the
 * database refused: a permission wall dressed up as a broken feature.
 *
 * And because Next.js picks the layout from the URL, a Manager opening it
 * from their own menu was rendered by the moderator layout, whose menu has no
 * التقارير — so the reports link vanished on entering distribution and
 * returned on leaving. Moving the page is what actually fixes that, rather
 * than patching the menu to paper over a cross-tree jump that should never
 * have existed.
 */
export default async function DistributionPage({
  searchParams,
}: {
  searchParams: Promise<{ factory?: string }>;
}) {
  // The guard is the point; nothing on the page needs the profile itself
  // now that only one role can reach it.
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
