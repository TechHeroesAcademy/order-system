import { LayoutDashboard, ListOrdered, PackagePlus, Users } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

export default async function ModeratorLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner", "moderator");

  // This layout is shared by both roles — an Owner lands here too (e.g. via
  // "أوردر جديد" from their own dashboard, see /moderator/orders/new). The
  // Team screen only ever lived at /owner/team (this shared tree's own
  // /moderator/team route was removed) and stays Owner-only, so the nav
  // item only shows up for an Owner passing through here, never for a
  // Moderator.
  const navItems: NavItem[] = [
    { href: "/moderator", label: "الرئيسية", icon: LayoutDashboard },
    { href: "/moderator/orders", label: "الأوردرات", icon: ListOrdered },
    { href: "/moderator/orders/new", label: "أوردر جديد", icon: PackagePlus },
    ...(profile.role === "owner" ? [{ href: "/owner/team", label: "الفريق", icon: Users }] : []),
  ];

  return (
    <AppShell profile={profile} navItems={navItems} title="El Rewad">
      {children}
    </AppShell>
  );
}
