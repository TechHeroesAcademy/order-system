import { requireRole } from "@/lib/auth";
import { listStaff, listAllDriverRegionIds } from "@/lib/data/staff";
import { listRegions } from "@/lib/data/orders";
import { listFactories } from "@/lib/data/factories";
import { TeamManager } from "@/components/team/team-manager";

export default async function TeamPage() {
  const profile = await requireRole("owner");

  const [staff, factories, regions, driverRegionsMap] = await Promise.all([
    listStaff(),
    listFactories(),
    listRegions(),
    listAllDriverRegionIds(),
  ]);

  return (
    <TeamManager
      staff={staff}
      factories={factories}
      regions={regions}
      driverRegionsMap={driverRegionsMap}
      viewerRole={profile.role}
    />
  );
}
