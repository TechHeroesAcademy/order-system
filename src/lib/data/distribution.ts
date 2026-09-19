import "server-only";
import { createClient } from "@/lib/supabase/server";
import type { OrderListRow } from "./orders";


/**
 * Data for the bulk distribution board — orders waiting for a manager to
 * approve who delivers them, grouped by area.
 *
 * No join to profiles for the suggested driver: orders.assigned_driver_name
 * is already stamped by the 0032 trigger when create_order_internal's
 * auto-suggestion picks someone, and reading the snapshot means the name
 * survives even if that account is later removed.
 */


/** Orders still waiting for approval, optionally narrowed to one factory. */
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

/**
 * Orders that have no driver and aren't finished — the "somebody needs to
 * deal with this" queue.
 *
 * Deliberately a derived predicate rather than only the needs_allocation
 * flag: a brand-new order with no driver (nobody covers its area yet, or a
 * manager cleared the suggestion) belongs here just as much as one orphaned
 * by a driver being removed. The flag, set only by driver removal, is what
 * sorts the urgent ones to the top and explains why.
 */
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
