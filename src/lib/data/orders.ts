import "server-only";
import { createClient } from "@/lib/supabase/server";
import type {
  DashboardStats,
  DelayedOrderRow,
  DriverPerformanceRow,
  FactoryOrderRow,
  MonthlyReport,
  DailyReport,
  Order,
  OrderChatChannel,
  OrderHistoryEntry,
  OrderMessage,
  OrderStatus,
  Region,
  TopRegionRow,
} from "@/types/database";

export interface OrderFilters {
  status?: OrderStatus | "all";
  regionId?: string | "all";
  driverId?: string | "all";
  search?: string;
  dateFrom?: string;
  dateTo?: string;
  minPieces?: number;
  maxPieces?: number;
  page?: number;
  pageSize?: number;
}

export interface OrderListRow extends Order {
  region: { name: string } | null;
}

export interface OrderListResult {
  orders: OrderListRow[];
  total: number;
}

/** Owner/Moderator order list with search + filters, newest first. */
export async function listOrders(filters: OrderFilters = {}): Promise<OrderListResult> {
  const supabase = await createClient();
  const page = filters.page ?? 1;
  const pageSize = filters.pageSize ?? 25;
  const from = (page - 1) * pageSize;
  const to = from + pageSize - 1;

  // assigned_driver_name / assigned_factory_name come straight off orders
  // (migration 0032) rather than a live join to profiles — a join would
  // silently lose the name the moment that driver/factory account is
  // deleted, which is exactly the case this list needs to keep showing.
  let query = supabase
    .from("orders")
    .select("*, region:regions(name)", { count: "exact" })
    .order("created_at", { ascending: false });

  if (filters.status && filters.status !== "all") {
    query = query.eq("status", filters.status);
  }
  if (filters.regionId && filters.regionId !== "all") {
    query = query.eq("region_id", filters.regionId);
  }
  if (filters.driverId && filters.driverId !== "all") {
    query = query.eq("assigned_driver_id", filters.driverId);
  }
  if (filters.search?.trim()) {
    const term = filters.search.trim();
    query = query.or(
      `order_number.ilike.%${term}%,customer_name.ilike.%${term}%,customer_phone.ilike.%${term}%`,
    );
  }
  if (filters.dateFrom) {
    query = query.gte("created_at", filters.dateFrom);
  }
  if (filters.dateTo) {
    // dateTo is a plain date (YYYY-MM-DD); include the whole day.
    query = query.lt("created_at", `${filters.dateTo}T23:59:59.999`);
  }
  if (filters.minPieces != null) {
    query = query.gte("pieces_count", filters.minPieces);
  }
  if (filters.maxPieces != null) {
    query = query.lte("pieces_count", filters.maxPieces);
  }

  const { data, error, count } = await query.range(from, to);
  if (error) throw error;
  return { orders: (data as unknown as OrderListRow[]) ?? [], total: count ?? 0 };
}

export async function getOrderById(id: string): Promise<Order | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("orders").select("*").eq("id", id).maybeSingle();
  if (error) throw error;
  return (data as Order) ?? null;
}

/**
 * Delivery codes for a page of orders in one round trip, keyed by order id —
 * the batch counterpart to getOrderDeliveryCodeAction (which stays for the
 * order-detail "reveal" flow). Used so the orders list can show every row's
 * code without firing one RPC per row. Owner/Moderator only — enforced by
 * get_order_delivery_codes() itself (see migration 0018); an empty array
 * short-circuits without a round trip since RPC calls with `= any('{}')`
 * are legal but pointless here.
 */
export async function getOrderDeliveryCodesMap(orderIds: string[]): Promise<Record<string, string>> {
  if (orderIds.length === 0) return {};
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_order_delivery_codes", { p_order_ids: orderIds });
  if (error) throw error;
  const map: Record<string, string> = {};
  for (const row of (data as { order_id: string; code: string }[]) ?? []) {
    map[row.order_id] = row.code;
  }
  return map;
}

/**
 * One of the two per-order chat threads — 'driver' (driver <-> Owner/
 * Moderator, migration 0018) or 'factory' (factory <-> Owner/Moderator,
 * migration 0019). Reads go straight through RLS (order_messages_select) —
 * same pattern as orders/order_history/notifications — so this is just a
 * plain select, gated by whether the current user is even allowed to see
 * any rows at all (an unauthorized caller simply gets an empty array back,
 * not an error, since RLS filters rather than rejects on SELECT).
 */
export async function getOrderMessages(orderId: string, channel: OrderChatChannel): Promise<OrderMessage[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("order_messages")
    .select("*, sender:profiles!order_messages_sender_id_fkey(full_name)")
    .eq("order_id", orderId)
    .eq("channel", channel)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data as unknown as OrderMessage[]) ?? [];
}

export async function getOrderHistory(orderId: string): Promise<OrderHistoryEntry[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("order_history")
    .select("*")
    .eq("order_id", orderId)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data as OrderHistoryEntry[]) ?? [];
}

/** Orders assigned to the current driver (RLS already scopes this, but we also filter for clarity). */
export async function listMyDriverOrders(driverId: string): Promise<Order[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("assigned_driver_id", driverId)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data as Order[]) ?? [];
}

export async function listFactoryOrders(): Promise<FactoryOrderRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("factory_orders_view")
    .select("*")
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data as FactoryOrderRow[]) ?? [];
}

/**
 * Every order this factory was ever assigned to that has since moved past
 * its own active window (collected/at_factory/ready) — with_driver,
 * delivered, refused, or cancelled. Backed by the same factory_orders_view
 * as listFactoryOrders(), which migration 0022 changed to keep showing a
 * factory any order it's assigned to regardless of status (previously it
 * disappeared the moment the driver picked it back up, same as this row
 * would 404 on the factory's own order-detail page — see that migration's
 * comment for the full report and root cause). Newest-first, since this is
 * a look-back list rather than a work queue.
 *
 * An explicit positive `.in()` over the four statuses that actually belong
 * in history, rather than `.not(...)` over the three active ones — a
 * negation would also (wrongly) sweep in 'new'/'assigned', an order that
 * hasn't even been collected yet and was never meant to be visible to the
 * factory at all (see 0023, which closed that same gap at the RLS/view
 * level after it was caught the same way listFactoryOrders() shows it —
 * this list staying an explicit allow-list is a second, independent guard
 * against that class of bug, not a relied-upon one).
 */
export async function listFactoryOrderHistory(): Promise<FactoryOrderRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("factory_orders_view")
    .select("*")
    .in("status", ["with_driver", "delivered", "refused", "cancelled"])
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data as FactoryOrderRow[]) ?? [];
}

export async function getFactoryOrderByNumber(orderNumber: string): Promise<FactoryOrderRow | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("factory_orders_view")
    .select("*")
    .eq("order_number", orderNumber.trim().toUpperCase())
    .maybeSingle();
  if (error) throw error;
  return (data as FactoryOrderRow) ?? null;
}

/**
 * A single order for the factory's own detail page — supports the factory
 * chat channel and the "open this order" notification click-through, and
 * (as of migration 0022, corrected by 0023) any order this factory was
 * ever actually involved with — collected/at_factory/ready/with_driver/
 * delivered/refused/cancelled — resolves here permanently. Before 0022 this
 * went through the same active-status-only filter as the dashboard tabs, so
 * an order that had moved past 'ready' 404'd here — reported as "press the
 * order number and it gives an error." 0022's first pass over-corrected
 * that and briefly also exposed 'new'/'assigned' orders (before the driver
 * has even collected them) — 0023 closed that gap; a factory never sees an
 * order that far ahead of its own involvement. An unassigned order still
 * only resolves here while active (collected/at_factory/ready), same as
 * before — nothing to permanently attribute it to once it's no longer
 * assigned to a specific factory.
 */
export async function getFactoryOrderById(id: string): Promise<FactoryOrderRow | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("factory_orders_view").select("*").eq("id", id).maybeSingle();
  if (error) throw error;
  return (data as FactoryOrderRow) ?? null;
}

export async function listRegions(): Promise<Region[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("regions").select("*").order("name");
  if (error) throw error;
  return (data as Region[]) ?? [];
}

export async function getDashboardStats(): Promise<DashboardStats> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("dashboard_stats").single();
  if (error) throw error;
  return data as DashboardStats;
}

export async function getDailyReport(day?: string): Promise<DailyReport> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .rpc("daily_report", day ? { p_day: day } : {})
    .single();
  if (error) throw error;
  return data as DailyReport;
}

export async function getMonthlyReport(month?: string): Promise<MonthlyReport> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .rpc("monthly_report", month ? { p_month: month } : {})
    .single();
  if (error) throw error;
  return data as MonthlyReport;
}

export async function getDriverPerformance(): Promise<DriverPerformanceRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("driver_performance_report");
  if (error) throw error;
  return (data as DriverPerformanceRow[]) ?? [];
}

export async function getDelayedOrders(): Promise<DelayedOrderRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("delayed_orders_report");
  if (error) throw error;
  return (data as DelayedOrderRow[]) ?? [];
}

export async function getTopRegions(): Promise<TopRegionRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("top_regions_report");
  if (error) throw error;
  return (data as TopRegionRow[]) ?? [];
}
