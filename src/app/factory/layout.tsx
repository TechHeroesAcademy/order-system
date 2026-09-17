import { ListOrdered } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [{ href: "/factory", label: "الأوردرات", icon: ListOrdered }];

export default async function FactoryLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("factory");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="El Rewad">
      {children}
    </AppShell>
  );
}
