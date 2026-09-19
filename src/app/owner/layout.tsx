import { LayoutDashboard, ListOrdered, BarChart3, Users, Split } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [
  { href: "/owner", label: "الرئيسية", icon: LayoutDashboard },
  { href: "/owner/orders", label: "الأوردرات", icon: ListOrdered },
  // The board lives in the shared /moderator tree (same as "أوردر جديد");
  // a Manager reaching it from here gets the full controls.
  { href: "/moderator/distribution", label: "التوزيع", icon: Split },
  { href: "/owner/reports", label: "التقارير", icon: BarChart3 },
  { href: "/owner/team", label: "الفريق", icon: Users },
];

export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("owner");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="El Rewad">
      {children}
    </AppShell>
  );
}
