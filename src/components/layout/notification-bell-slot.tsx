import { Bell } from "lucide-react";
import { Button } from "@/components/ui/button";
import { NotificationBell } from "./notification-bell";
import { getNotificationFeed } from "@/lib/data/staff";
import type { UserRole } from "@/types/database";

export async function NotificationBellSlot({ profileId, role }: { profileId: string; role: UserRole }) {
  const { notifications, unreadCount } = await getNotificationFeed(profileId, 15);

  return <NotificationBell notifications={notifications as never} unreadCount={unreadCount} role={role} />;
}

export function NotificationBellSkeleton() {
  return (
    <Button variant="ghost" size="icon" disabled>
      <Bell className="opacity-60" />
    </Button>
  );
}
