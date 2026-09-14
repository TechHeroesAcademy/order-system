"use client";

import { useTransition } from "react";
import { Bell } from "lucide-react";
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
import type { AppNotification } from "@/types/database";

export function NotificationBell({
  notifications,
  unreadCount,
}: {
  notifications: AppNotification[];
  unreadCount: number;
}) {
  const [pending, startTransition] = useTransition();

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="icon" className="relative">
          <Bell />
          {unreadCount > 0 && (
            <Badge
              variant="destructive"
              className="absolute -top-1 -start-1 h-5 min-w-5 justify-center px-1 text-[10px]"
            >
              {unreadCount > 9 ? "9+" : unreadCount}
            </Badge>
          )}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-80 p-0" align="start">
        <div className="flex items-center justify-between border-b p-3">
          <p className="text-sm font-medium">الإشعارات</p>
          {unreadCount > 0 && (
            <Button
              variant="ghost"
              size="sm"
              disabled={pending}
              onClick={() => startTransition(() => { void markAllNotificationsReadAction(); })}
            >
              تعليم الكل كمقروء
            </Button>
          )}
        </div>
        <ScrollArea className="h-80">
          {notifications.length === 0 ? (
            <p className="p-4 text-center text-sm text-muted-foreground">لا توجد إشعارات</p>
          ) : (
            <ul>
              {notifications.map((n) => (
                <li
                  key={n.id}
                  className={`cursor-pointer border-b p-3 text-sm last:border-0 hover:bg-accent ${!n.is_read ? "bg-accent/50" : ""}`}
                  onClick={() => {
                    if (!n.is_read) startTransition(() => { void markNotificationReadAction(n.id); });
                  }}
                >
                  <p className="font-medium">{n.title}</p>
                  {n.body && <p className="text-muted-foreground">{n.body}</p>}
                  <p className="mt-1 text-xs text-muted-foreground">{formatRelative(n.created_at)}</p>
                </li>
              ))}
            </ul>
          )}
        </ScrollArea>
      </PopoverContent>
    </Popover>
  );
}
