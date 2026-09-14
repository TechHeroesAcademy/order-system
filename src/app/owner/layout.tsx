import { LayoutDashboard, ListOrdered, BarChart3, Users } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [
  { href: "/owner", label: "الرئيسية", icon: LayoutDashboard },
  { href: "/owner/orders", label: "الأوردرات", icon: ListOrdered },
  { href: "/owner/reports", label: "التقارير", icon: BarChart3 },
  { href: "/owner/team", label: "الفريق", icon: Users },
];

export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="نظام الأوردرات">
      {children}
    </AppShell>
  );
}
