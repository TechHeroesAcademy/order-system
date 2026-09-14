import { requireRole } from "@/lib/auth";
import { listStaff, listDriverRegionIds } from "@/lib/data/staff";
import { listRegions } from "@/lib/data/orders";
import { TeamManager } from "@/components/team/team-manager";

export default async function TeamPage() {
  await requireRole("owner");

  const [staff, regions] = await Promise.all([listStaff(), listRegions()]);
  const drivers = staff.filter((s) => s.role === "driver");

  const driverRegionEntries = await Promise.all(
    drivers.map(async (d) => [d.id, await listDriverRegionIds(d.id)] as const),
  );
  const driverRegionsMap = Object.fromEntries(driverRegionEntries);

  return <TeamManager staff={staff} regions={regions} driverRegionsMap={driverRegionsMap} />;
}
