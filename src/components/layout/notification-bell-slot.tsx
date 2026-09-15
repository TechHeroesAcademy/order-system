import { Bell } from "lucide-react";
import { Button } from "@/components/ui/button";
import { NotificationBell } from "./notification-bell";
import { listNotifications, getUnreadNotificationCount } from "@/lib/data/staff";

/**
 * Split out from AppShell so it can stream in behind a <Suspense> boundary
 * instead of blocking the whole header (and therefore the whole page) on
 * two extra queries on every single navigation. AppShell used to `await`
 * these itself before rendering anything — title, nav links, avatar,
 * children, all of it — which is the main reason switching between tabs
 * felt slow: every click paid for a notifications fetch it didn't need
 * before the rest of the page could even start rendering.
 */
export async function NotificationBellSlot({ profileId }: { profileId: string }) {
  const [notifications, unreadCount] = await Promise.all([
    listNotifications(profileId, 15),
    getUnreadNotificationCount(profileId),
  ]);

  return <NotificationBell notifications={notifications as never} unreadCount={unreadCount} />;
}

export function NotificationBellSkeleton() {
  return (
    <Button variant="ghost" size="icon" disabled>
      <Bell className="opacity-60" />
    </Button>
  );
}
