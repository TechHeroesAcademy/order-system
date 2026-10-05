import "server-only";
import { createClient } from "@/lib/db/client";
import type { Factory } from "@/types/database";

export async function listFactories(): Promise<Factory[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("factories").select("*").order("name");
  if (error) throw error;
  return (data as Factory[]) ?? [];
}

