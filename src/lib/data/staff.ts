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

export async function listDriverRegionIds(driverId: string): Promise<string[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("driver_regions")
    .select("region_id")
    .eq("driver_id", driverId);
  if (error) throw error;
  return (data ?? []).map((r) => r.region_id as string);
}

/**
 * Region ids for every driver in one query, keyed by driver id. Prefer this
 * over calling listDriverRegionIds() in a loop — the Team page used to fire
 * one request per driver (N+1), which is the difference between one request
 * and a dozen+ as the team grows.
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
