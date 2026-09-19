import "server-only";
import { createClient } from "@/lib/supabase/server";
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

/**
 * Every order, unpaginated, for the "تحميل كل البيانات" CSV export
 * (Owner-only — enforced by orders_select_staff RLS same as everywhere
 * else, exportOrdersCsvAction also checks requireRole("owner") before
 * calling this). Supabase caps a single request at 1000 rows regardless of
 * .range(), so this pages through in 1000-row batches rather than assuming
 * one request covers "all" — correct today and still correct once this
 * business has more than 1000 orders.
 */
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
  // Capped because the open chat panel re-reads this thread on a timer, so
  // an unbounded select is paid again every few seconds rather than once.
  // 200 is far above any real thread — this is one conversation about one
  // pot-recoating job between a driver and a manager, not a group channel —
  // so in practice nothing is ever cut; it only stops a pathological thread
  // from being re-downloaded in full on every poll.
  //
  // Newest-first with a limit, then reversed, so the cap keeps the *most
  // recent* 200 messages. Ordering ascending and limiting would keep the
  // oldest 200 and hide everything current, which is the opposite of useful.
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

/**
 * The columns the driver's own order list actually renders. Selecting `*`
 * here shipped roughly forty columns per row to a phone — including every
 * lifecycle timestamp, both code-attempt counters, the customer's maps link
 * and the notes — to render a card showing six of them.
 */
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
  /** Every non-terminal order. Unbounded on purpose — a driver must see all of their open work. */
  active: DriverListOrder[];
  /** Only the page-size most recent finished orders. */
  completed: DriverListOrder[];
  /** Exact total of finished orders, independent of how many were fetched. */
  completedTotal: number;
}

/**
 * Orders assigned to the current driver (RLS already scopes this, but we
 * also filter for clarity).
 *
 * This used to be a single unbounded `select *`, and the page then threw
 * most of it away: it renders every active order but only `.slice(0, 30)`
 * of the completed ones. A driver with a long history was downloading their
 * entire career to a phone over mobile data to show thirty cards.
 *
 * Two bounded queries instead of one unbounded one. That is one extra round
 * trip, taken deliberately: the completed query asks for `count: "exact"`,
 * so the exact total still comes back — in the Content-Range header, not as
 * rows — and the "مكتملة (N)" tab count stays exactly the number it was
 * before. Nothing visible changes; only the number of rows on the wire does.
 */
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
