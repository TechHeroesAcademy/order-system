import { Bell } from "lucide-react";
import { Button } from "@/components/ui/button";
import { NotificationBell } from "./notification-bell";
import { listNotifications, getUnreadNotificationCount } from "@/lib/data/staff";
import type { UserRole } from "@/types/database";

export async function NotificationBellSlot({ profileId, role }: { profileId: string; role: UserRole }) {
  const [notifications, unreadCount] = await Promise.all([
    listNotifications(profileId, 15),
    getUnreadNotificationCount(profileId),
  ]);

  return <NotificationBell notifications={notifications as never} unreadCount={unreadCount} role={role} />;
}

export function NotificationBellSkeleton() {
  return (
    <Button variant="ghost" size="icon" disabled>
      <Bell className="opacity-60" />
    </Button>
  );
}
