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
  assigned_driver: { full_name: string } | null;
  assigned_factory: { full_name: string } | null;
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

  let query = supabase
    .from("orders")
    .select(
      "*, region:regions(name), assigned_driver:profiles!orders_assigned_driver_id_fkey(full_name), assigned_factory:profiles!orders_assigned_factory_id_fkey(full_name)",
      { count: "exact" },
    )
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
 * A per-order chat thread between the assigned driver and Owner/Moderator.
 * Reads go straight through RLS (order_messages_select, migration 0018) —
 * same pattern as orders/order_history/notifications — so this is just a
 * plain select, gated by whether the current user is even allowed to see
 * any rows at all (an unauthorized caller simply gets an empty array back,
 * not an error, since RLS filters rather than rejects on SELECT).
 */
export async function getOrderMessages(orderId: string): Promise<OrderMessage[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("order_messages")
    .select("*, sender:profiles!order_messages_sender_id_fkey(full_name)")
    .eq("order_id", orderId)
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
