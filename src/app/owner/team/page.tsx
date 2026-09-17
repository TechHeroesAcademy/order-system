import { requireRole } from "@/lib/auth";
import { listStaff, listAllDriverRegionIds } from "@/lib/data/staff";
import { listRegions } from "@/lib/data/orders";
import { listPickupPoints, listAllPickupPointRegionIds } from "@/lib/data/pickup-points";
import { TeamManager } from "@/components/team/team-manager";

export default async function TeamPage() {
  const profile = await requireRole("owner");

  const [staff, regions, driverRegionsMap, pickupPoints, pickupPointRegionsMap] = await Promise.all([
    listStaff(),
    listRegions(),
    listAllDriverRegionIds(),
    listPickupPoints(),
    listAllPickupPointRegionIds(),
  ]);

  return (
    <TeamManager
      staff={staff}
      regions={regions}
      driverRegionsMap={driverRegionsMap}
      pickupPoints={pickupPoints}
      pickupPointRegionsMap={pickupPointRegionsMap}
      viewerRole={profile.role}
    />
  );
}
