import { ListOrdered } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [{ href: "/driver", label: "أوردراتي", icon: ListOrdered }];

export default async function DriverLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("driver");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="المجد">
      {children}
    </AppShell>
  );
}
