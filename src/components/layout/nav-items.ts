import { LayoutDashboard, ListOrdered, BarChart3, Users, Split, PackagePlus } from "lucide-react";
import type { UserRole } from "@/types/database";
import type { NavItem } from "./app-shell";

/**
 * The navigation menu, decided by who you are — not by which folder the page
 * you are looking at happens to live in.
 *
 * That distinction is the whole point of this file. The distribution board
 * lives under /moderator (it is shared by both roles, and putting a second
 * copy under /owner would mean two screens to keep in step). Next.js picks
 * the layout from the URL, so a Manager clicking التوزيع was rendered by the
 * moderator layout — and that layout's menu has no التقارير in it. From the
 * Manager's side the reports screen simply vanished the moment they opened
 * distribution, and came back if they navigated away. الرئيسية and الأوردرات
 * quietly changed meaning at the same time, pointing at the moderator
 * versions of those pages instead of the Manager's own.
 *
 * Both layouts now call this, so the menu is identical everywhere for a
 * given person. It is also the only place a nav item can be added, which is
 * what stops the two menus drifting apart again.
 */
export function navItemsForRole(role: UserRole): NavItem[] {
  if (role === "owner") {
    return [
      { href: "/owner", label: "الرئيسية", icon: LayoutDashboard },
      { href: "/owner/orders", label: "الأوردرات", icon: ListOrdered },
      // Shared with Moderators; a Manager arriving here gets the full
      // controls, including approval.
      { href: "/moderator/distribution", label: "التوزيع", icon: Split },
      { href: "/owner/reports", label: "التقارير", icon: BarChart3 },
      { href: "/owner/team", label: "الفريق", icon: Users },
    ];
  }

  // Moderators have no reports screen and no team screen — /owner/team is
  // Manager-only and always was. "أوردر جديد" takes the slot those would
  // occupy; a Manager reaches the same page from the button on their own
  // dashboard instead, which is why it is not in their menu.
  return [
    { href: "/moderator", label: "الرئيسية", icon: LayoutDashboard },
    { href: "/moderator/orders", label: "الأوردرات", icon: ListOrdered },
    { href: "/moderator/distribution", label: "التوزيع", icon: Split },
    { href: "/moderator/orders/new", label: "أوردر جديد", icon: PackagePlus },
  ];
}
