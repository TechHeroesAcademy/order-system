"use client";

import { useMemo, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  AlertTriangle,
  Ban,
  Bell,
  Check,
  CheckCheck,
  Factory,
  MessageSquare,
  PackageCheck,
  PackagePlus,
  PackageX,
  Repeat,
  Truck,
  type LucideIcon,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { ScrollArea } from "@/components/ui/scroll-area";
import { formatRelative } from "@/lib/domain/format";
import { markAllNotificationsReadAction, markNotificationReadAction } from "@/lib/actions/notifications";
import type { AppNotification, UserRole } from "@/types/database";

const ORDER_DETAIL_BASE: Record<UserRole, string> = {
  owner: "/owner/orders",
  moderator: "/moderator/orders",
  driver: "/driver/orders",
  factory: "/login",
};

const LOOK: Record<string, { icon: LucideIcon; tint: string }> = {
  order_assigned: { icon: Truck, tint: "bg-amber-500/15 text-amber-700 dark:text-amber-400" },
  distribution_approved: { icon: CheckCheck, tint: "bg-amber-500/15 text-amber-700 dark:text-amber-400" },
  new_order: { icon: PackagePlus, tint: "bg-amber-500/15 text-amber-700 dark:text-amber-400" },
  chat_message: { icon: MessageSquare, tint: "bg-sky-500/10 text-sky-600 dark:text-sky-400" },
  order_collected: { icon: PackageCheck, tint: "bg-sky-500/10 text-sky-600 dark:text-sky-400" },
  driver_heading_to_factory: { icon: Truck, tint: "bg-sky-500/10 text-sky-600 dark:text-sky-400" },
  factory_received: { icon: Factory, tint: "bg-amber-500/10 text-amber-600 dark:text-amber-400" },
  ready_for_pickup: { icon: Factory, tint: "bg-amber-500/10 text-amber-600 dark:text-amber-400" },
  driver_left_factory: { icon: Truck, tint: "bg-amber-500/10 text-amber-600 dark:text-amber-400" },
  order_delivered: { icon: Check, tint: "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400" },
  order_refused: { icon: PackageX, tint: "bg-destructive/10 text-destructive" },
  delivery_retry: { icon: Repeat, tint: "bg-sky-500/10 text-sky-600 dark:text-sky-400" },
  order_cancelled: { icon: Ban, tint: "bg-destructive/10 text-destructive" },
  needs_allocation: { icon: AlertTriangle, tint: "bg-destructive/10 text-destructive" },
  driver_reassigned: { icon: Repeat, tint: "bg-muted text-muted-foreground" },
  factory_reassigned: { icon: Repeat, tint: "bg-muted text-muted-foreground" },
  reassigned_away: { icon: Repeat, tint: "bg-muted text-muted-foreground" },
};

const FALLBACK = { icon: Bell, tint: "bg-muted text-muted-foreground" };

function startOfDay(iso: string): number {
  const d = new Date(iso);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

function dayLabel(stamp: number): string {
  const today = startOfDay(new Date().toISOString());
  const day = 86_400_000;
  if (stamp === today) return "اليوم";
  if (stamp === today - day) return "أمس";
  return new Intl.DateTimeFormat("ar-EG-u-nu-latn", {
    day: "numeric",
    month: "long",
  }).format(new Date(stamp));
}

export function NotificationBell({
  notifications,
  unreadCount,
  role,
}: {
  notifications: AppNotification[];
  unreadCount: number;
  role: UserRole;
}) {
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  const groups = useMemo(() => {
    const byDay = new Map<number, AppNotification[]>();
    for (const n of notifications) {
      const key = startOfDay(n.created_at);
      const list = byDay.get(key);
      if (list) list.push(n);
      else byDay.set(key, [n]);
    }
    return [...byDay.entries()].sort((a, b) => b[0] - a[0]);
  }, [notifications]);

  function openNotification(n: AppNotification) {
    if (!n.is_read) startTransition(() => { void markNotificationReadAction(n.id); });
    if (n.order_id) router.push(`${ORDER_DETAIL_BASE[role]}/${n.order_id}`);
  }

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          className="relative"
          aria-label={unreadCount > 0 ? `الإشعارات، ${unreadCount} غير مقروء` : "الإشعارات"}
        >
          <Bell />
          {unreadCount > 0 && (
            <Badge
              variant="destructive"
              className="absolute -top-1 -start-1 h-5 min-w-5 justify-center px-1 text-[10px] tabular-nums"
            >
              {unreadCount > 9 ? "9+" : unreadCount}
            </Badge>
          )}
        </Button>
      </PopoverTrigger>

      <PopoverContent
        className="w-[min(22rem,calc(100vw-1.5rem))] overflow-hidden p-0"
        align="start"
        sideOffset={8}
      >
        <div className="flex items-center justify-between gap-2 border-b bg-muted/30 px-3 py-2.5">
          <div className="flex items-center gap-2">
            <p className="text-sm font-semibold">الإشعارات</p>
            {unreadCount > 0 && (
              <span className="rounded-full bg-amber-700/10 px-2 py-0.5 text-[11px] font-medium text-amber-700 tabular-nums dark:bg-amber-400/15 dark:text-amber-400">
                {unreadCount} جديد
              </span>
            )}
          </div>
          {unreadCount > 0 && (
            <Button
              variant="ghost"
              size="sm"
              className="h-7 px-2 text-xs"
              disabled={pending}
              onClick={() => startTransition(() => { void markAllNotificationsReadAction(); })}
            >
              <CheckCheck className="size-3.5" />
              تعليم الكل
            </Button>
          )}
        </div>

        <ScrollArea className="max-h-[min(26rem,60vh)]">
          {notifications.length === 0 ? (
            <div className="flex flex-col items-center gap-2 px-4 py-10 text-center">
              <span className="flex size-10 items-center justify-center rounded-full bg-muted">
                <Bell className="size-5 text-muted-foreground" />
              </span>
              <p className="text-sm font-medium">لا توجد إشعارات</p>
              <p className="text-xs text-muted-foreground">
                ستظهر هنا تحديثات الأوردرات والرسائل
              </p>
            </div>
          ) : (
            groups.map(([stamp, items]) => (
              <div key={stamp}>
                <p className="sticky top-0 z-10 border-b bg-background/95 px-3 py-1.5 text-[11px] font-medium text-muted-foreground backdrop-blur">
                  {dayLabel(stamp)}
                </p>
                <ul className="divide-y">
                  {items.map((n) => {
                    const look = LOOK[n.type] ?? FALLBACK;
                    const Icon = look.icon;
                    return (
                      <li key={n.id}>
                        <button
                          type="button"
                          onClick={() => openNotification(n)}
                          className={`flex w-full items-start gap-3 px-3 py-3 text-start transition-colors hover:bg-accent focus-visible:bg-accent focus-visible:outline-none ${
                            n.is_read ? "" : "bg-amber-500/[0.07]"
                          }`}
                        >
                          <span
                            className={`mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full ${look.tint}`}
                          >
                            <Icon className="size-4" />
                          </span>

                          <span className="min-w-0 flex-1">
                            <span className="flex items-start justify-between gap-2">
                              <span
                                className={`text-sm leading-snug ${n.is_read ? "font-medium" : "font-semibold"}`}
                              >
                                {n.title}
                              </span>
                              {!n.is_read && (
                                <span
                                  className="mt-1.5 size-2.5 shrink-0 rounded-full bg-amber-700 dark:bg-amber-400"
                                  aria-label="غير مقروء"
                                />
                              )}
                            </span>
                            {n.body && (
                              <span className="mt-0.5 line-clamp-2 block text-xs leading-relaxed text-muted-foreground">
                                {n.body}
                              </span>
                            )}
                            <span className="mt-1 block text-[11px] text-muted-foreground">
                              {formatRelative(n.created_at)}
                            </span>
                          </span>
                        </button>
                      </li>
                    );
                  })}
                </ul>
              </div>
            ))
          )}
        </ScrollArea>
      </PopoverContent>
    </Popover>
  );
}
