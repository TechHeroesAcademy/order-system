import { ListOrdered, PackagePlus } from "lucide-react";
import { requireRole } from "@/lib/auth";
import { AppShell, type NavItem } from "@/components/layout/app-shell";

const NAV_ITEMS: NavItem[] = [
  { href: "/driver", label: "أوردراتي", icon: ListOrdered },
  // A job negotiated on the doorstep. Self-assigned, no approval — see
  // driver_create_field_order (migration 0046).
  { href: "/driver/orders/new", label: "أوردر جديد", icon: PackagePlus },
];

export default async function DriverLayout({ children }: { children: React.ReactNode }) {
  const profile = await requireRole("driver");
  return (
    <AppShell profile={profile} navItems={NAV_ITEMS} title="El Rewad">
      {children}
    </AppShell>
  );
}
