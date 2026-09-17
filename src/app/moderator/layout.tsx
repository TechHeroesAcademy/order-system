import { LayoutDashboard, ListOrdered, PackagePlus, Users } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [
  { href: "/moderator", label: "الرئيسية", icon: LayoutDashboard },
  { href: "/moderator/orders", label: "الأوردرات", icon: ListOrdered },
  { href: "/moderator/orders/new", label: "أوردر جديد", icon: PackagePlus },
  { href: "/moderator/team", label: "الفريق", icon: Users },
];

export default async function ModeratorLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner", "moderator");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="El Rewad">
      {children}
    </AppShell>
  );
}
