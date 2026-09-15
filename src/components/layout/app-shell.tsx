import Link from "next/link";
import { Suspense } from "react";
import type { LucideIcon } from "lucide-react";
import { NotificationBellSlot, NotificationBellSkeleton } from "./notification-bell-slot";
import { SignOutButton } from "./sign-out-button";
import { IdleLogoutWatcher } from "./idle-logout-watcher";
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
  owner: "صاحب النظام",
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
          this is the one element present on every screen for every role. */}
      <header className="sticky top-0 z-40 bg-primary text-primary-foreground shadow-sm">
        <div className="flex h-14 items-center gap-3 px-4">
          <p className="font-bold whitespace-nowrap">{title}</p>
          <Badge variant="outline" className="hidden border-primary-foreground/30 text-primary-foreground sm:inline-flex">
            {ROLE_LABELS_AR[profile.role]}
          </Badge>
          <div className="flex-1" />
          <div className="[&_button]:text-primary-foreground [&_button]:hover:bg-primary-foreground/10">
            <Suspense fallback={<NotificationBellSkeleton />}>
              <NotificationBellSlot profileId={profile.id} />
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
        <nav className="flex gap-1 overflow-x-auto border-t border-primary-foreground/15 px-2 py-1.5">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="flex shrink-0 items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium text-primary-foreground/75 transition-colors hover:bg-primary-foreground/10 hover:text-primary-foreground"
            >
              <item.icon className="size-4" />
              {item.label}
            </Link>
          ))}
        </nav>
      </header>
      <main className="mx-auto w-full max-w-6xl flex-1 p-4">{children}</main>
    </div>
  );
}
