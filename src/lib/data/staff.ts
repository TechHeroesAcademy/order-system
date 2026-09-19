import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { Profile, UserRole } from "@/types/database";

export async function listStaff(role?: UserRole): Promise<Profile[]> {
  const supabase = await createClient();
  let query = supabase.from("profiles").select("*").order("full_name");
  if (role) query = query.eq("role", role);
  const { data, error } = await query;
  if (error) throw error;
  return (data as Profile[]) ?? [];
}

/**
 * Region ids for every driver in one query, keyed by driver id.
 *
 * There used to be a single-driver listDriverRegionIds() beside this, left
 * over from before the Team page was fixed; it had no callers and its only
 * plausible use was inside a loop, which is precisely the N+1 this function
 * exists to avoid (one request per driver instead of one request, growing
 * with the team). It has been removed so it can't be reached for again.
 */
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

export async function getUnreadNotificationCount(userId: string): Promise<number> {
  const supabase = await createClient();
  const { count, error } = await supabase
    .from("notifications")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("is_read", false);
  if (error) throw error;
  return count ?? 0;
}

export async function listNotifications(userId: string, limit = 20) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("notifications")
    .select("*")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data ?? [];
}

/**
 * Which factories each manager covers, keyed by manager id (migration 0040).
 *
 * One query for the whole team rather than one per manager — same reason as
 * listAllDriverRegionIds above.
 *
 * This is used for one thing only: deciding whose phone rings for a chat
 * message on an order. It does not scope what any manager can see. They all
 * still see every order and every in-app notification, which was a
 * deliberate decision and is unchanged.
 */
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
