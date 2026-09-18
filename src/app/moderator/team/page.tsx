import { requireRole } from "@/lib/auth";
import { listStaff, listAllDriverRegionIds } from "@/lib/data/staff";
import { listRegions } from "@/lib/data/orders";
import { TeamManager } from "@/components/team/team-manager";

/**
 * Same screen as /owner/team, reused here for the Moderator. `<TeamManager>`
 * itself scopes what a Moderator can see/do via `viewerRole` — it can only
 * create or activate/deactivate driver and factory accounts, never an owner
 * or another moderator (also enforced server-side in admin.ts + RLS).
 */
export default async function ModeratorTeamPage() {
  const profile = await requireRole("owner", "moderator");

  const [staff, regions, driverRegionsMap] = await Promise.all([
    listStaff(),
    listRegions(),
    listAllDriverRegionIds(),
  ]);

  return (
    <TeamManager staff={staff} regions={regions} driverRegionsMap={driverRegionsMap} viewerRole={profile.role} />
  );
}
