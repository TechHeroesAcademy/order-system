import Link from "next/link";
import { Suspense } from "react";
import type { LucideIcon } from "lucide-react";
import { NotificationBellSlot, NotificationBellSkeleton } from "./notification-bell-slot";
import { SignOutButton } from "./sign-out-button";
import { IdleLogoutWatcher } from "./idle-logout-watcher";
import { BrandBadge } from "@/components/shared/brand-logo";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import type { Profile } from "@/types/database";

export interface NavItem {
  href: string;
  label: string;
  icon: LucideIcon;
}

const ROLE_LABELS_AR: Record<string, string> = {
  owner: "مدير",
  moderator: "موديريتور",
  driver: "مندوب",
  factory: "المصنع",
};

export function AppShell({
  profile,
  navItems,
  title,
  children,
}: {
  profile: Profile;
  navItems: NavItem[];
  title: string;
  children: React.ReactNode;
}) {
  const initials = profile.full_name.trim().slice(0, 1);

  return (
    <div className="flex min-h-screen flex-col">
      <IdleLogoutWatcher />
      {/* Bold yellow top bar, DHL-style — the brand block lives here since
          this is the one element present on every screen for every role.
          pt-[env(safe-area-inset-top)] is defensive: the iOS status bar is
          set to "default" (opaque, reserves its own space) in layout.tsx's
          appleWebApp config, so this is normally 0px — but it means this
          header stays correct even if that ever changes back to a
          translucent/edge-to-edge status bar, instead of silently breaking
          again the way it did with no safe-area handling at all. */}
      <header className="sticky top-0 z-40 bg-primary pt-[env(safe-area-inset-top)] text-primary-foreground shadow-sm">
        <div className="flex h-14 items-center gap-3 px-4">
          {/* White mount behind the badge for contrast against the bar's own
              (yellow) brand color — the badge's own red doesn't need to
              match it, same idea as a logo sticker on a colored sign. */}
          <span className="sr-only">{title}</span>
          <div className="flex items-center rounded-md bg-white px-2 py-1 shadow-sm">
            <BrandBadge className="h-5 w-auto" />
          </div>
          <Badge variant="outline" className="hidden border-primary-foreground/30 text-primary-foreground sm:inline-flex">
            {ROLE_LABELS_AR[profile.role]}
          </Badge>
          <div className="flex-1" />
          <div className="[&_button]:text-primary-foreground [&_button]:hover:bg-primary-foreground/10">
            <Suspense fallback={<NotificationBellSkeleton />}>
              <NotificationBellSlot profileId={profile.id} role={profile.role} />
            </Suspense>
          </div>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button className="rounded-full outline-none ring-offset-primary transition-transform hover:scale-105 focus-visible:ring-2 focus-visible:ring-primary-foreground/60">
                <Avatar className="border-2 border-primary-foreground/40">
                  <AvatarFallback className="bg-primary-foreground/15 text-primary-foreground">
                    {initials}
                  </AvatarFallback>
                </Avatar>
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start">
              <DropdownMenuLabel>
                <p>{profile.full_name}</p>
                <p className="text-xs font-normal text-muted-foreground">{ROLE_LABELS_AR[profile.role]}</p>
              </DropdownMenuLabel>
              <DropdownMenuSeparator />
              <SignOutButton />
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
        {/* Wraps rather than scrolling sideways. It used to be overflow-x-auto,
            which silently pushed later items off the edge of a phone screen
            with nothing to indicate more existed — measured at 375px and
            below, adding a fifth item hid exactly التقارير and الفريق, which
            read as them having been deleted.

            The icons are decorative (every item has a label) and cost ~22px
            each, so they're dropped below sm — that's what keeps all five on
            a single row at 375px+ instead of forcing a second row and eating
            another 32px of a phone screen. Narrower than that it wraps, which
            is fine: a taller menu beats a hidden one. */}
        <nav className="flex flex-wrap gap-1 border-t border-primary-foreground/15 px-2 py-1.5">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="flex shrink-0 items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium text-primary-foreground/75 transition-colors hover:bg-primary-foreground/10 hover:text-primary-foreground"
            >
              <item.icon className="hidden size-4 sm:block" />
              {item.label}
            </Link>
          ))}
        </nav>
      </header>
      {/* Full-width instead of a boxed max-w-6xl column — on a wide monitor
          the old cap left large empty margins on both sides; the generous
          responsive gutters below keep long lines/tables from stretching
          edge-to-edge while still using the whole screen. */}
      <main className="w-full flex-1 p-4 sm:px-6 lg:px-10 xl:px-16">{children}</main>
    </div>
  );
}
