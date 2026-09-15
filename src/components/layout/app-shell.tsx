import Link from "next/link";
import type { LucideIcon } from "lucide-react";
import { NotificationBell } from "./notification-bell";
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
import { listNotifications } from "@/lib/data/staff";
import { getUnreadNotificationCount } from "@/lib/data/staff";
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

export async function AppShell({
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
  const [notifications, unreadCount] = await Promise.all([
    listNotifications(profile.id, 15),
    getUnreadNotificationCount(profile.id),
  ]);

  const initials = profile.full_name.trim().slice(0, 1);

  return (
    <div className="flex min-h-screen flex-col">
      <IdleLogoutWatcher />
      <header className="sticky top-0 z-40 border-b bg-background/95 backdrop-blur supports-backdrop-filter:bg-background/80">
        <div className="flex h-14 items-center gap-3 px-4">
          <p className="font-bold whitespace-nowrap">{title}</p>
          <Badge variant="outline" className="hidden sm:inline-flex">
            {ROLE_LABELS_AR[profile.role]}
          </Badge>
          <div className="flex-1" />
          <NotificationBell notifications={notifications as never} unreadCount={unreadCount} />
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button className="outline-none">
                <Avatar>
                  <AvatarFallback>{initials}</AvatarFallback>
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
        <nav className="flex gap-1 overflow-x-auto border-t px-2 py-1.5">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="flex shrink-0 items-center gap-1.5 rounded-md px-3 py-1.5 text-sm text-muted-foreground hover:bg-accent hover:text-accent-foreground"
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
