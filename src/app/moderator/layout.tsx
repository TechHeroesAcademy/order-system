import { requireRole } from "@/lib/auth";
import { AppShell } from "@/components/layout/app-shell";
import { navItemsForRole } from "@/components/layout/nav-items";

export default async function ModeratorLayout({ children }: { children: React.ReactNode }) {
  // Shared by both roles: a Manager lands here for the distribution board and
  // for "أوردر جديد", both of which live in this tree rather than being
  // duplicated under /owner.
  //
  // The menu therefore has to follow the person, not the URL. Building it
  // from this layout's own list is what made التقارير disappear for a Manager
  // the moment they opened التوزيع — see nav-items.ts.
  const profile = await requireRole("owner", "moderator");

  return (
    <AppShell profile={profile} navItems={navItemsForRole(profile.role)} title="El Rewad">
      {children}
    </AppShell>
  );
}
