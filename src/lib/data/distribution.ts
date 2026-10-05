import "server-only";
import { createClient } from "@/lib/db/client";
import type { OrderListRow } from "./orders";

export async function listPendingDistribution(factoryId?: string): Promise<OrderListRow[]> {
  const supabase = await createClient();
  let query = supabase
    .from("orders")
    .select("*, region:regions(name)")
    .eq("status", "new")
    .order("created_at", { ascending: true });

  if (factoryId) query = query.eq("assigned_factory_id", factoryId);

  const { data, error } = await query;
  if (error) throw error;
  return (data as unknown as OrderListRow[]) ?? [];
}

export async function listUnallocatedOrders(): Promise<OrderListRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("orders")
    .select("*, region:regions(name)")
    .is("assigned_driver_id", null)
    .not("status", "in", "(delivered,cancelled,refused)")
    .order("needs_allocation_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data as unknown as OrderListRow[]) ?? [];
}
