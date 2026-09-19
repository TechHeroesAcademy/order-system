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

// listActiveFactories() and getFactory(factoryId) used to live here. Both
// were written ahead of a caller that never arrived — nothing in the app
// referenced either one. They are not kept "just in case": an unused query
// helper is a maintenance cost with no upside, and either is two lines to
// write again the day something actually needs it.
