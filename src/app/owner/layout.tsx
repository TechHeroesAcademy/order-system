import { requireRole } from "@/lib/auth";
import { AppShell } from "@/components/layout/app-shell";
import { navItemsForRole } from "@/components/layout/nav-items";

export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner");
  return (
    <AppShell profile={profile} navItems={navItemsForRole(profile.role)} title="El Rewad">
      {children}
    </AppShell>
  );
}
