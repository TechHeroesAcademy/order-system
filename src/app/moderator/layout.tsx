import { LayoutDashboard, ListOrdered, PackagePlus } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [
  { href: "/moderator", label: "الرئيسية", icon: LayoutDashboard },
  { href: "/moderator/orders", label: "الأوردرات", icon: ListOrdered },
  { href: "/moderator/orders/new", label: "أوردر جديد", icon: PackagePlus },
];

export default async function ModeratorLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner", "moderator");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="نظام الأوردرات">
      {children}
    </AppShell>
  );
}
