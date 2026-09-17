import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { PickupPoint } from "@/types/database";

/** Every pickup point, active or not — the management screen shows both, the
 * driver-facing page filters to active only. Ordered by name for a stable list. */
export async function listPickupPoints(): Promise<PickupPoint[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("pickup_points").select("*").order("name");
  if (error) throw error;
  return (data as PickupPoint[]) ?? [];
}

/** pickup_point_id -> region_id[], same shape as listAllDriverRegionIds(). */
export async function listAllPickupPointRegionIds(): Promise<Record<string, string[]>> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("pickup_point_regions").select("pickup_point_id, region_id");
  if (error) throw error;
  const map: Record<string, string[]> = {};
  for (const row of data ?? []) {
    const pickupPointId = row.pickup_point_id as string;
    (map[pickupPointId] ??= []).push(row.region_id as string);
  }
  return map;
}
