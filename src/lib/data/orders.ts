import "server-only";
import { createClient } from "@/lib/db/client";
import { TERMINAL_STATUSES } from "@/lib/domain/order-status";
import type {
  DashboardStats,
  DelayedOrderRow,
  DriverPerformanceRow,
  MonthlyReport,
  DailyReport,
  Order,
  OrderChatChannel,
  OrderHistoryEntry,
  OrderMessage,
  OrderStatus,
  Region,
  TopRegionRow,
  OrderSourceRow,
  OrderCreatorRow,
  OrderCustomerContext,
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

export async function listOrders(filters: OrderFilters = {}): Promise<OrderListResult> {
  const supabase = await createClient();
  const page = filters.page ?? 1;
  const pageSize = filters.pageSize ?? 25;
  const from = (page - 1) * pageSize;
  const to = from + pageSize - 1;

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
    query = query.orIlike(["order_number", "customer_name", "customer_phone"], term);
  }
  if (filters.dateFrom) {
    query = query.gte("created_at", filters.dateFrom);
  }
  if (filters.dateTo) {
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

export async function listAllOrdersForExport(): Promise<OrderListRow[]> {
  const supabase = await createClient();
  const pageSize = 1000;
  const rows: OrderListRow[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase
      .from("orders")
      .select("*, region:regions(name)")
      .order("created_at", { ascending: false })
      .range(from, from + pageSize - 1);
    if (error) throw error;
    const batch = (data as unknown as OrderListRow[]) ?? [];
    rows.push(...batch);
    if (batch.length < pageSize) break;
  }
  return rows;
}

export async function getOrderById(id: string): Promise<Order | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("orders").select("*").eq("id", id).maybeSingle();
  if (error) throw error;
  return (data as Order) ?? null;
}

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

export async function getOrderMessages(orderId: string, channel: OrderChatChannel): Promise<OrderMessage[]> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("order_messages")
    .select("*, sender:profiles!order_messages_sender_id_fkey(full_name)")
    .eq("order_id", orderId)
    .eq("channel", channel)
    .order("created_at", { ascending: false })
    .limit(200);
  if (error) throw error;
  return ((data as unknown as OrderMessage[]) ?? []).reverse();
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

const DRIVER_LIST_COLUMNS =
  "id, order_number, status, customer_name, customer_address, region_id, created_at, delivered_at, refused_at";

export type DriverListOrder = Pick<
  Order,
  | "id"
  | "order_number"
  | "status"
  | "customer_name"
  | "customer_address"
  | "region_id"
  | "created_at"
  | "delivered_at"
  | "refused_at"
>;

export interface DriverOrders {
  active: DriverListOrder[];
  completed: DriverListOrder[];
  completedTotal: number;
}

export async function listMyDriverOrders(
  driverId: string,
  completedLimit = 30,
): Promise<DriverOrders> {
  const supabase = await createClient();

  const [activeRes, completedRes] = await Promise.all([
    supabase
      .from("orders")
      .select(DRIVER_LIST_COLUMNS)
      .eq("assigned_driver_id", driverId)
      .not("status", "in", `(${TERMINAL_STATUSES.join(",")})`)
      .order("created_at", { ascending: false }),
    supabase
      .from("orders")
      .select(DRIVER_LIST_COLUMNS, { count: "exact" })
      .eq("assigned_driver_id", driverId)
      .in("status", TERMINAL_STATUSES)
      .order("created_at", { ascending: false })
      .limit(completedLimit),
  ]);

  if (activeRes.error) throw activeRes.error;
  if (completedRes.error) throw completedRes.error;

  return {
    active: (activeRes.data as unknown as DriverListOrder[]) ?? [],
    completed: (completedRes.data as unknown as DriverListOrder[]) ?? [],
    completedTotal: completedRes.count ?? 0,
  };
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

export async function getOrdersBySource(month?: string): Promise<OrderSourceRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("orders_by_source_report", month ? { p_month: month } : {});
  if (error) throw error;
  return (data as OrderSourceRow[]) ?? [];
}

export async function getOrdersByCreator(month?: string): Promise<OrderCreatorRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("orders_by_creator_report", month ? { p_month: month } : {});
  if (error) throw error;
  return (data as OrderCreatorRow[]) ?? [];
}

export async function getOrderCustomerContext(orderId: string): Promise<OrderCustomerContext | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("order_customer_context", { p_order_id: orderId });
  if (error) return null;
  return (data as OrderCustomerContext[] | null)?.[0] ?? null;
}
