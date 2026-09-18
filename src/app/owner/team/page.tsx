import { requireRole } from "@/lib/auth";
import { listStaff, listAllDriverRegionIds } from "@/lib/data/staff";
import { listRegions } from "@/lib/data/orders";
import { TeamManager } from "@/components/team/team-manager";

export default async function TeamPage() {
  const profile = await requireRole("owner");

  const [staff, regions, driverRegionsMap] = await Promise.all([
    listStaff(),
    listRegions(),
    listAllDriverRegionIds(),
  ]);

  return (
    <TeamManager staff={staff} regions={regions} driverRegionsMap={driverRegionsMap} viewerRole={profile.role} />
  );
}
