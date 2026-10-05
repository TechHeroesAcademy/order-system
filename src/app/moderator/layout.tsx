import { requireRole } from "@/lib/auth";
import { AppShell } from "@/components/layout/app-shell";
import { navItemsForRole } from "@/components/layout/nav-items";

export default async function ModeratorLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner", "moderator");

  return (
    <AppShell profile={profile} navItems={navItemsForRole(profile.role)} title="El Rewad">
      {children}
    </AppShell>
  );
}
