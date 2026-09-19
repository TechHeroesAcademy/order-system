import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { Factory } from "@/types/database";

/**
 * Factories are workshops, not staff accounts — see migration 0033. This
 * replaces the old `listStaff("factory")`, which read them out of `profiles`
 * back when each one had a login.
 *
 * Readable by every signed-in role: drivers need the address and map pin of
 * the workshop they're driving to, and staff need the list to route orders.
 */
export async function listFactories(): Promise<Factory[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("factories").select("*").order("name");
  if (error) throw error;
  return (data as Factory[]) ?? [];
}

/** Active factories only — for pickers where choosing a retired workshop would be rejected anyway. */
export async function listActiveFactories(): Promise<Factory[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("factories")
    .select("*")
    .eq("is_active", true)
    .order("name");
  if (error) throw error;
  return (data as Factory[]) ?? [];
}

export async function getFactory(factoryId: string): Promise<Factory | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("factories").select("*").eq("id", factoryId).maybeSingle();
  if (error) throw error;
  return (data as Factory | null) ?? null;
}
