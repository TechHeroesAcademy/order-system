import { LayoutDashboard, ListOrdered, BarChart3, Users, Split, PackagePlus } from "lucide-react";
import type { UserRole } from "@/types/database";
import type { NavItem } from "./app-shell";

export function navItemsForRole(role: UserRole): NavItem[] {
  if (role === "owner") {
    return [
      { href: "/owner", label: "الرئيسية", icon: LayoutDashboard },
      { href: "/owner/orders", label: "الأوردرات", icon: ListOrdered },
      { href: "/owner/distribution", label: "التوزيع", icon: Split },
      { href: "/owner/reports", label: "التقارير", icon: BarChart3 },
      { href: "/owner/team", label: "الفريق", icon: Users },
    ];
  }

  return [
    { href: "/moderator", label: "الرئيسية", icon: LayoutDashboard },
    { href: "/moderator/orders", label: "الأوردرات", icon: ListOrdered },
    { href: "/moderator/orders/new", label: "أوردر جديد", icon: PackagePlus },
  ];
}
