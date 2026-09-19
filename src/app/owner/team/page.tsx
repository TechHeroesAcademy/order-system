import { requireRole } from "@/lib/auth";
import { listStaff, listAllDriverRegionIds, listManagerFactoryIds } from "@/lib/data/staff";
import { listRegions } from "@/lib/data/orders";
import { listFactories } from "@/lib/data/factories";
import { TeamManager } from "@/components/team/team-manager";

export default async function TeamPage() {
  const profile = await requireRole("owner");

  const [staff, factories, regions, driverRegionsMap, managerFactoriesMap] = await Promise.all([
    listStaff(),
    listFactories(),
    listRegions(),
    listAllDriverRegionIds(),
    listManagerFactoryIds(),
  ]);

  return (
    <TeamManager
      staff={staff}
      factories={factories}
      regions={regions}
      driverRegionsMap={driverRegionsMap}
      managerFactoriesMap={managerFactoriesMap}
      viewerRole={profile.role}
    />
  );
}
