import "server-only";
import { createClient, currentProfileId } from "@/lib/db/client";
import { withUserContext } from "@/lib/db/with-user-context";
import type { AppNotification, Profile, UserRole } from "@/types/database";

export async function listStaff(role?: UserRole): Promise<Profile[]> {
  const supabase = await createClient();
  let query = supabase.from("profiles").select("*").order("full_name");
  if (role) query = query.eq("role", role);
  const { data, error } = await query;
  if (error) throw error;
  return (data as Profile[]) ?? [];
}

export async function listAllDriverRegionIds(): Promise<Record<string, string[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("driver_regions").select("driver_id, region_id");
  if (error) throw error;
  const map: Record<string, string[]> = {};
  for (const row of data ?? []) {
    const driverId = row.driver_id as string;
    (map[driverId] ??= []).push(row.region_id as string);
  }
  return map;
}

export interface NotificationFeed {
  notifications: AppNotification[];
  unreadCount: number;
}

export async function getNotificationFeed(
  userId: string,
  limit = 20,
): Promise<NotificationFeed> {
  const profileId = await currentProfileId();
  return withUserContext(profileId, async (q) => {
    const res = await q.query<{ items: AppNotification[] | null; unread: number }>(
      `select
         (select coalesce(json_agg(n order by n.created_at desc), '[]'::json)
            from (
              select * from public.notifications
               where user_id = $1
               order by created_at desc
               limit $2
            ) n)                                             as items,
         (select count(*)
            from public.notifications
           where user_id = $1 and is_read = false)           as unread`,
      [userId, limit],
    );
    const row = res.rows[0];
    return {
      notifications: row?.items ?? [],
      unreadCount: Number(row?.unread ?? 0),
    };
  });
}

export async function listManagerFactoryIds(): Promise<Record<string, string[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("manager_factories").select("manager_id, factory_id");
  if (error) throw error;
  const map: Record<string, string[]> = {};
  for (const row of data ?? []) {
    const managerId = row.manager_id as string;
    (map[managerId] ??= []).push(row.factory_id as string);
  }
  return map;
}
